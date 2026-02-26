module Conduits
  # Atomically assigns queued directives to a polling territory.
  # Returns DirectiveLease structures ready for Nexus consumption.
  class PollService
    DEFAULT_LEASE_TTL = 300 # 5 minutes
    DEFAULT_RETRY_AFTER = 2 # seconds

    Result = Data.define(:directives, :lease_ttl_seconds, :retry_after_seconds)

    def initialize(territory:, supported_profiles:, max_claims: 1)
      @territory = territory
      @supported_profiles = supported_profiles
      @max_claims = [max_claims, 5].min # cap at 5 per poll
    end

    def call
      lease_directives(skip_locked: true)
    rescue ActiveRecord::StatementInvalid => e
      # SQLite doesn't support SKIP LOCKED — fall back to advisory locking
      raise unless e.message.include?("SKIP LOCKED")
      lease_directives(skip_locked: false)
    end

    private

    def lease_directives(skip_locked:)
      leases = []

      # Load-aware: skip poll entirely if territory reports full capacity
      unless @territory.has_capacity?
        return Result.new(
          directives: [],
          lease_ttl_seconds: DEFAULT_LEASE_TTL,
          retry_after_seconds: DEFAULT_RETRY_AFTER
        )
      end

      remaining_slots = @territory.max_concurrent - @territory.running_directives_count

      Directive.transaction do
        scope = Directive
          .assignable
          .includes(:facility)
          .where(account_id: @territory.account_id)
          .where(sandbox_profile: @supported_profiles)
          .order(:created_at)
          .limit([@max_claims, remaining_slots].min)

        scope = scope.lock("FOR UPDATE SKIP LOCKED") if skip_locked

        scope.each do |directive|
          # Skip if facility is locked by another directive
          next if directive.facility.locked? && directive.facility.locked_by_directive_id != directive.id

          # Skip if this territory's sandbox driver for the profile is unhealthy
          next unless @territory.sandbox_healthy?(directive.sandbox_profile)

          # Re-validate policy at lease time (may have changed since creation)
          current_eval = Conduits::PolicyResolver.new(directive).call
          if current_eval.approval_verdict == :forbidden
            directive.cancel!
            audit_for(directive).record(
              "directive.lease_policy_revalidated",
              severity: "warn",
              payload: { "action" => "canceled", "reason" => "policy_now_forbidden" }
            )
            next
          end
          if current_eval.effective_capabilities != directive.effective_capabilities
            directive.update_columns(
              effective_capabilities: current_eval.effective_capabilities,
              policy_snapshot: current_eval.policy_snapshot
            )
            audit_for(directive).record(
              "directive.lease_policy_revalidated",
              payload: { "action" => "capabilities_updated" }
            )
          end

          begin
            directive.territory = @territory
            directive.lease_expires_at = Time.current + DEFAULT_LEASE_TTL.seconds
            directive.lease!

            # Lock the facility (atomic; raises if already locked by another directive).
            # If this fails due to a race, revert the lease to avoid stranding the directive in `leased`
            # without issuing a token to the territory.
            directive.facility.lock!(directive)
          rescue Facility::LockConflict
            directive.expire_lease! if directive.leased?
            next
          end

          token = DirectiveToken.encode(
            directive_id: directive.id,
            territory_id: @territory.id,
            ttl: DEFAULT_LEASE_TTL.seconds
          )

          leases << build_lease(directive, token)
        end
      end

      Result.new(
        directives: leases,
        lease_ttl_seconds: DEFAULT_LEASE_TTL,
        retry_after_seconds: leases.empty? ? DEFAULT_RETRY_AFTER : 0
      )
    end

    def audit_for(directive)
      AuditService.new(account: directive.account, directive: directive)
    end

    def build_lease(directive, token)
      {
        directive_id: directive.id,
        directive_token: token,
        spec: build_spec(directive),
      }
    end

    def build_spec(directive)
      {
        directive_id: directive.id,
        facility: {
          id: directive.facility_id,
          mount: "/workspace",
          repo_url: directive.facility.repo_url,
        }.compact,
        sandbox_profile: directive.sandbox_profile,
        command: directive.command,
        shell: directive.shell || "/bin/sh",
        cwd: directive.cwd || "/workspace",
        timeout_seconds: directive.timeout_seconds,
        limits: directive.limits,
        capabilities: directive.effective_capabilities,
        artifacts: directive.artifacts_manifest,
      }
    end
  end
end
