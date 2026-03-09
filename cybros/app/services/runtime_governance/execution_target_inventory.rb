module RuntimeGovernance
  class ExecutionTargetInventory
    def self.list(current_target:, permission_mode:, visible_only: true, relation: ExecutionTarget.all)
      new(
        current_target: current_target,
        permission_mode: permission_mode,
        visible_only: visible_only,
        relation: relation,
      ).list
    end

    def self.get(current_target:, permission_mode:, execution_target_id:, visible_only: true, relation: ExecutionTarget.all)
      new(
        current_target: current_target,
        permission_mode: permission_mode,
        visible_only: visible_only,
        relation: relation,
      ).get(execution_target_id:)
    end

    def initialize(current_target:, permission_mode:, visible_only:, relation:)
      @current_target = current_target
      @permission_mode = permission_mode.to_s.strip
      @visible_only = visible_only
      @relation = relation
    end

    def list
      base_scope
        .order(Arel.sql("LOWER(execution_targets.name) ASC"), :id)
        .map { |target| summary_for(target) }
    end

    def get(execution_target_id:)
      target = base_scope.find_by(id: execution_target_id)
      return summary_for(target) if target.present?

      AgentCore::ValidationError.raise!(
        "Selected execution target could not be found.",
        code: "cybros.execution_targets.not_found",
        details: { execution_target_id: execution_target_id, visible_only: visible_only },
      )
    end

    private

      attr_reader :current_target, :permission_mode, :visible_only, :relation

      def base_scope
        scope = relation.includes(:execution_location, :workspace)
        return scope unless visible_only

        scope.visible_for_runtime
      end

      def summary_for(target)
        {
          "id" => target.id,
          "name" => target.name,
          "location_label" => target.execution_location&.name.to_s,
          "workspace_label" => target.workspace&.name.to_s,
          "workspace_path_hint" => target.workspace&.root_path.to_s,
          "capability_tags" => Array(target.workspace&.capability_tags),
          "availability" => availability_for(target),
          "health_status" => health_status_for(target),
          "is_default" => current_target.present? && current_target.id.to_s == target.id.to_s,
          "switch_decision_preview" => preview_for(target),
        }
      end

      def preview_for(target)
        ExecutionTargetSwitchPolicy.evaluate(
          current_target: current_target,
          proposed_target: target,
          permission_mode: permission_mode,
        )
      end

      def availability_for(target)
        RuntimeGovernance::ExecutionTargetSwitchPolicy.visible_target?(target) ? "available" : "unavailable"
      end

      def health_status_for(target)
        statuses = [target.status, target.execution_location&.status, target.workspace&.status].compact
        return "unhealthy" if statuses.include?("unhealthy")
        return "inactive" if statuses.any? { |value| value != "active" }

        "healthy"
      end
  end
end
