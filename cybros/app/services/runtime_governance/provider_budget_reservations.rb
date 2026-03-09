module RuntimeGovernance
  module ProviderBudgetReservations
    ACTIVE_WINDOW_STATUSES = %w[active settled released].freeze
    RESERVATION_TTL = 30.seconds

    module_function

    def acquire!(
      provider_credential:,
      provider_request_id:,
      request_units:,
      estimated_tokens:,
      owner_type:,
      owner_id:,
      now: Time.current,
      reservation_ttl: RESERVATION_TTL
    )
      provider_credential.with_lock do
        existing = ProviderBudgetReservation.find_by(provider_credential: provider_credential, provider_request_id: provider_request_id)
        return { decision: "acquired", reservation: existing, runtime_wait: nil } if existing

        reconcile_expired_locked!(provider_credential: provider_credential, now: now)

        if over_budget?(provider_credential: provider_credential, request_units: request_units, estimated_tokens: estimated_tokens, now: now)
          runtime_wait =
            RuntimeWaits.park!(
              owner_type: owner_type,
              owner_id: owner_id,
              reason_type: "provider_limit",
              subject_type: "llm_provider_credential",
              subject_id: provider_credential.id,
              retry_at: now + 15.seconds,
              details: {
                "provider_request_id" => provider_request_id,
                "provider_credential_id" => provider_credential.id,
              },
              now: now,
            )
          return { decision: "parked", reservation: nil, runtime_wait: runtime_wait }
        end

        reservation =
          ProviderBudgetReservation.create!(
            provider_credential: provider_credential,
            provider_request_id: provider_request_id,
            request_units: request_units,
            estimated_tokens: estimated_tokens,
            reserved_until: now + reservation_ttl,
            status: "active",
            reconciliation_metadata: {},
          )
        RuntimeWaits.cancel!(
          owner_type: owner_type,
          owner_id: owner_id,
          reason_type: "provider_limit",
          subject_type: "llm_provider_credential",
          subject_id: provider_credential.id,
        )
        { decision: "acquired", reservation: reservation, runtime_wait: nil }
      end
    end

    def settle!(provider_credential:, provider_request_id:, actual_tokens:, now: Time.current)
      provider_credential.with_lock do
        reservation = ProviderBudgetReservation.find_by!(provider_credential: provider_credential, provider_request_id: provider_request_id)
        reservation.update!(
          status: "settled",
          actual_tokens: actual_tokens,
          reserved_until: [reservation.reserved_until, now].compact.min,
        )
        reservation
      end
    end

    def release!(provider_credential:, provider_request_id:, now: Time.current)
      provider_credential.with_lock do
        reservation = ProviderBudgetReservation.find_by!(provider_credential: provider_credential, provider_request_id: provider_request_id)
        reservation.update!(status: "released", reserved_until: [reservation.reserved_until, now].compact.min)
        reservation
      end
    end

    def reconcile_expired!(provider_credential:, now: Time.current)
      provider_credential.with_lock do
        reconcile_expired_locked!(provider_credential: provider_credential, now: now)
      end
    end

    def reconcile_expired_locked!(provider_credential:, now:)
      ProviderBudgetReservation.active.where(provider_credential: provider_credential).where("reserved_until <= ?", now).update_all(
        status: "expired",
        updated_at: now,
      )
    end
    private_class_method :reconcile_expired_locked!

    def over_budget?(provider_credential:, request_units:, estimated_tokens:, now:)
      active_reservations = ProviderBudgetReservation.active.where(provider_credential: provider_credential).where("reserved_until > ?", now)
      active_request_units = active_reservations.sum(:request_units)
      return true if active_request_units + request_units > provider_credential.max_concurrent_requests

      window_start = now - 1.minute
      window_reservations =
        ProviderBudgetReservation.where(provider_credential: provider_credential, status: ACTIVE_WINDOW_STATUSES)
          .where("created_at >= ?", window_start)
      request_total = window_reservations.sum(:request_units)
      return true if request_total + request_units > provider_credential.requests_per_minute

      token_total = window_reservations.to_a.sum { |reservation| reservation.actual_tokens || reservation.estimated_tokens }
      token_total + estimated_tokens > provider_credential.tokens_per_minute
    end
    private_class_method :over_budget?
  end
end
