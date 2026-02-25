module Conduits
  class DiffBlobCleanupJob < ApplicationJob
    include Conduits::EnvConfigurable

    queue_as :default

    def perform(
      ttl_days: env_int("CONDUITS_DIFF_BLOB_TTL_DAYS", 30),
      batch_size: env_int("CONDUITS_DIFF_BLOB_CLEANUP_BATCH_SIZE", 100),
      sleep_seconds: env_float("CONDUITS_DIFF_BLOB_CLEANUP_SLEEP_SECONDS", 0.05)
    )
      return if ttl_days <= 0 || batch_size <= 0

      cutoff = Time.current - ttl_days.days

      ids = ActiveStorage::Attachment
        .where(record_type: "Conduits::Directive", name: "diff_blob")
        .where("created_at < ?", cutoff)
        .order(:id)
        .limit(batch_size)
        .pluck(:id)

      ActiveStorage::Attachment.where(id: ids).order(:id).each do |attachment|
        attachment.purge
        sleep(sleep_seconds) if sleep_seconds.positive?
      rescue StandardError => e
        Rails.logger.warn(
          "Conduits::DiffBlobCleanupJob purge failed attachment_id=#{attachment.id} " \
          "error=#{e.class} message=#{e.message}"
        )
      end
    end
  end
end
