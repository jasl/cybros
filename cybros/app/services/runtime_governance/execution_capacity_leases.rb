module RuntimeGovernance
  module ExecutionCapacityLeases
    LEASE_TTL = 5.minutes

    module_function

    def acquire!(
      capacity:,
      execution_request_id:,
      holder_type:,
      holder_id:,
      slots: 1,
      now: Time.current,
      lease_ttl: LEASE_TTL
    )
      subject_type = capacity.fetch("scope_type")
      subject_id = capacity.fetch("scope_id")

      with_subject_lock(subject_type: subject_type, subject_id: subject_id) do
        existing = ExecutionCapacityLease.find_by(subject_type: subject_type, subject_id: subject_id, execution_request_id: execution_request_id)
        return { decision: "acquired", lease: existing, runtime_wait: nil } if existing

        reconcile_expired_locked!(subject_type: subject_type, subject_id: subject_id, now: now)

        active_slots = ExecutionCapacityLease.active.where(subject_type: subject_type, subject_id: subject_id)
          .where("lease_expires_at > ?", now)
          .sum(:slots)

        if active_slots + slots <= capacity.fetch("max_concurrent_tasks")
          lease =
            ExecutionCapacityLease.create!(
              subject_type: subject_type,
              subject_id: subject_id,
              execution_request_id: execution_request_id,
              holder_type: holder_type,
              holder_id: holder_id,
              slots: slots,
              lease_expires_at: now + lease_ttl,
              heartbeat_at: now,
              status: "active",
              recovery_metadata: {},
            )
          RuntimeWaits.cancel!(
            owner_type: holder_type,
            owner_id: holder_id,
            reason_type: "execution_capacity",
            subject_type: subject_type,
            subject_id: subject_id,
          )
          return { decision: "acquired", lease: lease, runtime_wait: nil }
        end

        existing_wait =
          RuntimeWait.parked.find_by(
            owner_type: holder_type,
            owner_id: holder_id,
            reason_type: "execution_capacity",
            subject_type: subject_type,
            subject_id: subject_id,
          )
        return { decision: "parked", lease: nil, runtime_wait: existing_wait } if existing_wait

        if RuntimeWaits.parked_count(reason_type: "execution_capacity", subject_type: subject_type, subject_id: subject_id) < capacity.fetch("max_queued_tasks")
          runtime_wait =
            RuntimeWaits.park!(
              owner_type: holder_type,
              owner_id: holder_id,
              reason_type: "execution_capacity",
              subject_type: subject_type,
              subject_id: subject_id,
              retry_at: now + 15.seconds,
              details: { "execution_request_id" => execution_request_id },
              now: now,
            )
          { decision: "parked", lease: nil, runtime_wait: runtime_wait }
        else
          { decision: "denied", lease: nil, runtime_wait: nil }
        end
      end
    end

    def release!(subject_type:, subject_id:, execution_request_id:, now: Time.current)
      with_subject_lock(subject_type: subject_type, subject_id: subject_id) do
        lease = ExecutionCapacityLease.active.find_by(subject_type: subject_type, subject_id: subject_id, execution_request_id: execution_request_id)
        return nil if lease.nil?

        lease.update!(status: "released", lease_expires_at: [lease.lease_expires_at, now].compact.min)
        RuntimeGovernance::RuntimeWaits.resume_next_parked!(
          reason_type: "execution_capacity",
          subject_type: subject_type,
          subject_id: subject_id,
          now: now,
        )
        lease
      end
    end

    def reconcile_expired!(subject_type:, subject_id:, now: Time.current)
      with_subject_lock(subject_type: subject_type, subject_id: subject_id) do
        reconcile_expired_locked!(subject_type: subject_type, subject_id: subject_id, now: now)
      end
    end

    def reconcile_expired_locked!(subject_type:, subject_id:, now:)
      ExecutionCapacityLease.active.where(subject_type: subject_type, subject_id: subject_id).where("lease_expires_at <= ?", now).update_all(
        status: "expired",
        updated_at: now,
      )
    end
    private_class_method :reconcile_expired_locked!

    def with_subject_lock(subject_type:, subject_id:)
      case subject_type.to_s
      when "agent"
        Agent.find(subject_id).with_lock { yield }
      else
        raise ArgumentError, "unsupported execution subject: #{subject_type}"
      end
    end
    private_class_method :with_subject_lock
  end
end
