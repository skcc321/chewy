# frozen_string_literal: true

require_relative '../../index'

# The class is responsible for accumulating in redis [type, ids]
# that were requested to be reindexed during `latency` seconds.
# The reindex job is going to be scheduled after a `latency` seconds.
# that job is going to read accumulated [type, ids] from the redis
# and reindex all them at once.
module Chewy
  class Strategy
    class DelayedSidekiq
      require_relative 'worker'

      LUA_SCRIPT = <<~LUA
        local timechunk_key = KEYS[1]
        local timechunks_key = KEYS[2]
        local serialize_data = ARGV[1]
        local at = ARGV[2]
        local ttl = tonumber(ARGV[3])

        local schedule_job = false

        -- Check if the 'sadd?' method is available
        if redis.call('exists', 'sadd?') == 1 then
          redis.call('sadd?', timechunk_key, serialize_data)
        else
          redis.call('sadd', timechunk_key, serialize_data)
        end

        -- Set expiration for timechunk_key
        redis.call('expire', timechunk_key, ttl)

        -- Check if timechunk_key exists in the sorted set
        if not redis.call('zrank', timechunks_key, timechunk_key) then
            -- Add timechunk_key to the sorted set
            redis.call('zadd', timechunks_key, at, timechunk_key)
            -- Set expiration for timechunks_key
            redis.call('expire', timechunks_key, ttl)
            schedule_job = true
        end

        return schedule_job
      LUA

      class Scheduler
        DEFAULT_TTL = 60 * 60 * 24 # in seconds
        DEFAULT_LATENCY = 10
        DEFAULT_MARGIN = 2
        DEFAULT_QUEUE = 'chewy'
        KEY_PREFIX = 'chewy:delayed_sidekiq'
        FALLBACK_FIELDS = 'all'
        FIELDS_IDS_SEPARATOR = ';'
        IDS_SEPARATOR = ','

        def initialize(type, ids, options = {})
          @type = type
          @ids = ids
          @options = options
        end

        # the diagram:
        #
        #  inputs:
        #  latency == 2
        #  reindex_time = Time.current
        #
        #  Parallel OR Sequential triggers of reindex:          |  What is going on in reindex store (Redis):
        #  --------------------------------------------------------------------------------------------------
        #                                                       |
        #  process 1 (reindex_time):                            |  chewy:delayed_sidekiq:CitiesIndex:1679347866 = [1]
        #    Schedule.new(CitiesIndex, [1]).postpone            |  chewy:delayed_sidekiq:timechunks = [{ score: 1679347866, "chewy:delayed_sidekiq:CitiesIndex:1679347866"}]
        #                                                       |  & schedule a DelayedSidekiq::Worker at 1679347869 (at + 3)
        #                                                       |    it will zpop chewy:delayed_sidekiq:timechunks up to 1679347866 score and reindex all ids with zpoped keys
        #                                                       |      chewy:delayed_sidekiq:CitiesIndex:1679347866
        #                                                       |
        #                                                       |
        #  process 2 (reindex_time):                            |  chewy:delayed_sidekiq:CitiesIndex:1679347866 = [1, 2]
        #    Schedule.new(CitiesIndex, [2]).postpone            |  chewy:delayed_sidekiq:timechunks = [{ score: 1679347866, "chewy:delayed_sidekiq:CitiesIndex:1679347866"}]
        #                                                       |  & do not schedule a new worker
        #                                                       |
        #                                                       |
        #  process 1 (reindex_time + (latency - 1).seconds):    |  chewy:delayed_sidekiq:CitiesIndex:1679347866 = [1, 2, 3]
        #    Schedule.new(CitiesIndex, [3]).postpone            |  chewy:delayed_sidekiq:timechunks = [{ score: 1679347866, "chewy:delayed_sidekiq:CitiesIndex:1679347866"}]
        #                                                       |  & do not schedule a new worker
        #                                                       |
        #                                                       |
        #  process 2 (reindex_time + (latency + 1).seconds):    |  chewy:delayed_sidekiq:CitiesIndex:1679347866 = [1, 2, 3]
        #    Schedule.new(CitiesIndex, [4]).postpone            |  chewy:delayed_sidekiq:CitiesIndex:1679347868 = [4]
        #                                                       |  chewy:delayed_sidekiq:timechunks = [
        #                                                       |    { score: 1679347866, "chewy:delayed_sidekiq:CitiesIndex:1679347866"}
        #                                                       |    { score: 1679347868, "chewy:delayed_sidekiq:CitiesIndex:1679347868"}
        #                                                       |  ]
        #                                                       |  & schedule a DelayedSidekiq::Worker at 1679347871 (at + 3)
        #                                                       |    it will zpop chewy:delayed_sidekiq:timechunks up to 1679347868 score and reindex all ids with zpoped keys
        #                                                       |      chewy:delayed_sidekiq:CitiesIndex:1679347866 (in case of failed previous reindex),
        #                                                       |      chewy:delayed_sidekiq:CitiesIndex:1679347868
        def postpone
          ::Sidekiq.redis do |redis|
            # do the redis stuff in a single command to avoid concurrency issues
            if redis.eval(LUA_SCRIPT, keys: [timechunk_key, timechunks_key], argv: [serialize_data, at, ttl])
              ::Sidekiq::Client.push(
                'queue' => sidekiq_queue,
                'at' => at + margin,
                'class' => Chewy::Strategy::DelayedSidekiq::Worker,
                'args' => [type_name, at]
              )
            end
          end
        end

      private

        attr_reader :type, :ids, :options

        # this method returns predictable value that jumps by latency value
        # another words each latency seconds it return the same value
        def at
          @at ||= begin
            schedule_at = latency.seconds.from_now.to_f

            (schedule_at - (schedule_at % latency)).to_i
          end
        end

        def fields
          options[:update_fields].presence || [FALLBACK_FIELDS]
        end

        def timechunks_key
          "#{KEY_PREFIX}:#{type_name}:timechunks"
        end

        def timechunk_key
          "#{KEY_PREFIX}:#{type_name}:#{at}"
        end

        def serialize_data
          [ids.join(IDS_SEPARATOR), fields.join(IDS_SEPARATOR)].join(FIELDS_IDS_SEPARATOR)
        end

        def type_name
          type.name
        end

        def latency
          strategy_config.latency || DEFAULT_LATENCY
        end

        def margin
          strategy_config.margin || DEFAULT_MARGIN
        end

        def ttl
          strategy_config.ttl || DEFAULT_TTL
        end

        def sidekiq_queue
          Chewy.settings.dig(:sidekiq, :queue) || DEFAULT_QUEUE
        end

        def strategy_config
          type.strategy_config.delayed_sidekiq
        end
      end
    end
  end
end
