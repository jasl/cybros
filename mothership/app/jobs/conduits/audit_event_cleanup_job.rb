module Conduits
  class AuditEventCleanupJob < ApplicationJob
    include Conduits::EnvConfigurable

    queue_as :default

    def perform(
      ttl_days: env_int("CONDUITS_AUDIT_EVENT_TTL_DAYS", 90),
      batch_size: env_int("CONDUITS_AUDIT_EVENT_CLEANUP_BATCH_SIZE", 1000),
      max_batches: env_int("CONDUITS_AUDIT_EVENT_CLEANUP_MAX_BATCHES", 10),
      sleep_seconds: env_float("CONDUITS_AUDIT_EVENT_CLEANUP_SLEEP_SECONDS", 0.05)
    )
      return if ttl_days <= 0 || batch_size <= 0 || max_batches <= 0

      cutoff = Time.current - ttl_days.days

      max_batches.times do
        ids = Conduits::AuditEvent
          .where("created_at < ?", cutoff)
          .order(created_at: :asc, id: :asc)
          .limit(batch_size)
          .pluck(:id)

        break if ids.empty?

        Conduits::AuditEvent.where(id: ids).delete_all

        sleep(sleep_seconds) if sleep_seconds.positive?
      end
    end
  end
end
