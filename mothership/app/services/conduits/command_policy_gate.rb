module Conduits
  # Evaluates device policy for a command before dispatch.
  # Returns a verdict that determines the command's initial state:
  #   :allowed         → command enters :queued state (ready for dispatch)
  #   :needs_approval  → command enters :awaiting_approval state
  #   :denied          → command is rejected (not created)
  class CommandPolicyGate
    Result = Data.define(:verdict, :reason, :policy_snapshot, :policies_applied)

    def initialize(account:, capability:, user: nil, facility: nil)
      @account = account
      @capability = capability
      @user = user
      @facility = facility
    end

    def call
      policies = Conduits::Policy.where(account_id: @account.id, active: true)
                                 .or(Conduits::Policy.where(account_id: nil, active: true))
                                 .order(:priority)
                                 .to_a

      # If no policies exist, default to allow-all for backwards compatibility.
      # This preserves the pre-policy-gate behavior where any declared capability was dispatchable.
      if policies.empty? || policies.all? { |p| p.device.blank? }
        return Result.new(
          verdict: :allowed,
          reason: nil,
          policy_snapshot: { "evaluated_at" => Time.current.iso8601, "policies_applied" => [] },
          policies_applied: []
        )
      end

      evaluation = DevicePolicyV1.evaluate(@capability, policies)
      snapshot = build_snapshot(policies, evaluation)

      Result.new(
        verdict: evaluation.verdict,
        reason: evaluation.reason,
        policy_snapshot: snapshot,
        policies_applied: policies.map(&:id)
      )
    end

    private

    def build_snapshot(policies, evaluation)
      {
        "evaluated_at" => Time.current.iso8601,
        "capability" => @capability,
        "verdict" => evaluation.verdict.to_s,
        "reason" => evaluation.reason,
        "policies_applied" => policies.map(&:id),
      }
    end
  end
end
