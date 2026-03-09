module RuntimeGovernance
  class ExecutionTargetSwitchPolicy
    def self.evaluate(current_target:, proposed_target:, permission_mode:)
      new(
        current_target: current_target,
        proposed_target: proposed_target,
        permission_mode: permission_mode,
      ).evaluate
    end

    def self.visible_target?(target)
      new(current_target: nil, proposed_target: target, permission_mode: Conversation::PERMISSION_MODES.first).visible_target?
    end

    def initialize(current_target:, proposed_target:, permission_mode:)
      @current_target = current_target
      @proposed_target = proposed_target
      @permission_mode = permission_mode.to_s.strip
    end

    def evaluate
      validate_permission_mode!

      unless visible_target?
        return decision(
          decision: "deny",
          reason: "execution_target_not_visible",
          visible: false,
          validated: false,
        )
      end

      if same_target?
        return decision(
          decision: "allow",
          reason: "same_target",
          visible: true,
          validated: true,
        )
      end

      if permission_mode == "full_access"
        return decision(
          decision: "allow",
          reason: "validated_visible_target",
          visible: true,
          validated: true,
        )
      end

      decision(
        decision: "confirm",
        reason: "different_visible_target_requires_confirmation",
        visible: true,
        validated: true,
      )
    end

    def visible_target?
      target = proposed_target
      return false unless target.is_a?(ExecutionTarget)

      location = target.execution_location
      workspace = target.workspace

      target.status == "active" &&
        location.present? &&
        location.status == "active" &&
        workspace.present? &&
        workspace.status == "active" &&
        workspace.execution_location_id == location.id
    end

    private

      attr_reader :current_target, :proposed_target, :permission_mode

      def same_target?
        current_target.present? &&
          proposed_target.present? &&
          current_target.id.to_s == proposed_target.id.to_s
      end

      def decision(decision:, reason:, visible:, validated:)
        {
          "decision" => decision,
          "reason" => reason,
          "permission_mode" => permission_mode,
          "current_target_id" => current_target&.id,
          "proposed_target_id" => proposed_target&.id,
          "visible" => visible,
          "validated" => validated,
          "requires_confirmation" => decision == "confirm",
        }
      end

      def validate_permission_mode!
        return if Conversation::PERMISSION_MODES.include?(permission_mode)

        AgentCore::ValidationError.raise!(
          "permission_mode must be one of: #{Conversation::PERMISSION_MODES.join(", ")}",
          code: "cybros.execution_target_switch_policy.permission_mode_invalid",
          details: { permission_mode: permission_mode, allowed_modes: Conversation::PERMISSION_MODES },
        )
      end
  end
end
