module Conduits
  class LogChunkCleanupJob < ApplicationJob
    include Conduits::EnvConfigurable

    queue_as :default

    def perform(
      ttl_days: env_int("CONDUITS_LOG_CHUNK_TTL_DAYS", 30),
      batch_size: env_int("CONDUITS_LOG_CHUNK_CLEANUP_BATCH_SIZE", 1000),
      max_batches: env_int("CONDUITS_LOG_CHUNK_CLEANUP_MAX_BATCHES", 10),
      sleep_seconds: env_float("CONDUITS_LOG_CHUNK_CLEANUP_SLEEP_SECONDS", 0.05)
    )
      return if ttl_days <= 0 || batch_size <= 0 || max_batches <= 0

      cutoff = Time.current - ttl_days.days

      max_batches.times do
        ids = Conduits::LogChunk
          .where("created_at < ?", cutoff)
          .order(created_at: :asc, id: :asc)
          .limit(batch_size)
          .pluck(:id)

        break if ids.empty?

        Conduits::LogChunk.where(id: ids).delete_all

        sleep(sleep_seconds) if sleep_seconds.positive?
      end
    end
  end
end
