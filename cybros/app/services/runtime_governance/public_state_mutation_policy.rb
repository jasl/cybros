module RuntimeGovernance
  class PublicStateMutationPolicy
    SUPPORTED_METHODS = %w[
      conversation.settings.update
      conversation.config.update
      lane.kv.set
      lane.kv.delete
    ].freeze

    def self.evaluate(method_name:, permission_mode:)
      new(method_name: method_name, permission_mode: permission_mode).evaluate
    end

    def initialize(method_name:, permission_mode:)
      @method_name = method_name.to_s
      @permission_mode = permission_mode.to_s
    end

    def evaluate
      unless SUPPORTED_METHODS.include?(method_name)
        return decision(decision: "deny", reason: "public_state_mutation_method_unknown")
      end

      outcome = policy_summary.dig("public_state_mutations", "default_outcome").to_s
      normalized_outcome = %w[allow confirm deny].include?(outcome) ? outcome : "deny"

      decision(
        decision: normalized_outcome,
        reason: "permission_preset_#{permission_mode}_public_state_mutation_#{normalized_outcome}",
      )
    end

    private

      attr_reader :method_name, :permission_mode

      def policy_summary
        @policy_summary ||= Cybros::Permissions::BundleCompiler.summary_for(permission_mode: permission_mode)
      end

      def decision(decision:, reason:)
        {
          "decision" => decision,
          "reason" => reason,
          "permission_mode" => permission_mode,
          "method_name" => method_name,
          "requires_confirmation" => decision == "confirm",
        }
      end
  end
end
