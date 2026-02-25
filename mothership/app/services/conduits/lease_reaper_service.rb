module Conduits
  class LeaseReaperService
    def call(limit: 200)
      expired = Directive.with_expired_lease.order(:lease_expires_at).limit(limit)

      expired.each do |directive|
        Directive.transaction do
          directive.lock!
          next unless directive.lease_expired?

          directive.expire_lease!

          AuditService.new(account: directive.account, directive: directive)
            .record("directive.lease_expired", severity: "warn", payload: {
              "territory_id" => directive.territory_id,
              "lease_expires_at" => directive.lease_expires_at&.iso8601,
            })
        end
      rescue StandardError => e
        Rails.logger.warn("[LeaseReaper] Failed to expire lease for directive=#{directive.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
