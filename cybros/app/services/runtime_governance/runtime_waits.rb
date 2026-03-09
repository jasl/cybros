module RuntimeGovernance
  module RuntimeWaits
    module_function

    def park!(owner_type:, owner_id:, reason_type:, subject_type:, subject_id:, retry_at:, details:, now: Time.current)
      existing =
        RuntimeWait.parked.find_by(
          owner_type: owner_type,
          owner_id: owner_id,
          reason_type: reason_type,
          subject_type: subject_type,
          subject_id: subject_id,
        )
      return existing if existing

      RuntimeWait.create!(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
        retry_at: retry_at,
        ordering_key: ordering_key_for(now: now),
        details: details,
        status: "parked",
      )
    rescue ActiveRecord::RecordNotUnique
      RuntimeWait.parked.find_by!(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      )
    end

    def next_ready(reason_type:, subject_type:, subject_id:, now: Time.current)
      RuntimeWait.parked.where(
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).where("retry_at <= ?", now).order(:ordering_key, :created_at, :id).first
    end

    def resume!(wait:)
      wait.update!(status: "resumed")
      wait
    end

    def cancel!(owner_type:, owner_id:, reason_type:, subject_type:, subject_id:)
      RuntimeWait.parked.where(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).update_all(status: "cancelled", updated_at: Time.current)
    end

    def parked_count(reason_type:, subject_type:, subject_id:)
      RuntimeWait.parked.where(
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).count
    end

    def ordering_key_for(now:)
      "#{now.utc.iso8601(6)}:#{SecureRandom.uuid}"
    end
    private_class_method :ordering_key_for
  end
end
