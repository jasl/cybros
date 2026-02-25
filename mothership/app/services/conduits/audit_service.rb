module Conduits
  # Structured recording of audit events for policy decisions,
  # directive lifecycle, and security-relevant actions.
  #
  # Usage:
  #   Conduits::AuditService.new(account: account, directive: directive, actor: user)
  #     .record("directive.created", payload: { command: "echo hello" })
  class AuditService
    def initialize(account:, directive: nil, actor: nil, context: {})
      @account = account
      @directive = directive
      @actor = actor
      @context = context
    end

    # Record a single audit event.
    #
    # @param event_type [String] e.g. "directive.created", "directive.policy_forbidden"
    # @param severity [String] "info", "warn", or "critical"
    # @param payload [Hash] event-specific data
    def record(event_type, severity: "info", payload: {})
      AuditEvent.create!(
        account: @account,
        directive: @directive,
        actor: @actor,
        event_type: event_type,
        severity: severity,
        payload: payload,
        context: @context
      )
    rescue ActiveRecord::RecordInvalid => e
      # Audit recording should never break the main flow
      Rails.logger.error("[AuditService] Failed to record #{event_type}: #{e.message}")
      nil
    end

    # Convenience: record with directive context auto-filled.
    def record_directive_event(event_type, severity: "info", extra: {})
      payload = build_directive_payload.merge(extra)
      record(event_type, severity: severity, payload: payload)
    end

    private

    def build_directive_payload
      return {} unless @directive

      {
        "directive_id" => @directive.id,
        "facility_id" => @directive.facility_id,
        "sandbox_profile" => @directive.sandbox_profile,
        "state" => @directive.state,
      }
    end
  end
end
