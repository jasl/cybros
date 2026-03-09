module AgentRpc
  module KernelServices
    class ExecutionTargets
      AutomationEntrypoint = Struct.new(:id, :permission_mode, :execution_target, keyword_init: true)

      def self.list(entrypoint:)
        new(entrypoint: entrypoint).list
      end

      def self.get(entrypoint:, execution_target_id:)
        new(entrypoint: entrypoint).get(execution_target_id:)
      end

      def self.propose!(draft:, execution_target_id:)
        new(entrypoint: resolve_entrypoint_for(draft), draft: draft).propose!(execution_target_id:)
      end

      def self.resolve_entrypoint_for(draft)
        return draft.conversation if draft.respond_to?(:conversation) && draft.conversation.present?
        return nil unless draft.respond_to?(:automation_id) && draft.automation_id.present?

        AutomationEntrypoint.new(
          id: draft.automation_id,
          permission_mode: draft.permission_mode,
          execution_target: draft.proposed_execution_target,
        )
      end

      def initialize(entrypoint:, draft: nil)
        @entrypoint = entrypoint
        @draft = draft
      end

      def list
        {
          "targets" => inventory.list,
        }
      end

      def get(execution_target_id:)
        {
          "target" => inventory.get(execution_target_id: execution_target_id),
        }
      end

      def propose!(execution_target_id:)
        ensure_draft!

        target =
          RuntimeGovernance::ExecutionTargetInventory.get(
            current_target: current_target,
            permission_mode: permission_mode,
            execution_target_id: execution_target_id,
            visible_only: false,
          )

        proposed_target = ExecutionTarget.includes(:execution_location, :workspace).find(target.fetch("id"))
        switch_decision =
          RuntimeGovernance::ExecutionTargetSwitchPolicy.evaluate(
            current_target: current_target,
            proposed_target: proposed_target,
            permission_mode: permission_mode,
          )

        apply_proposal!(proposed_target) if switch_decision.fetch("decision") == "allow"

        {
          "target" => target,
          "switch_decision" => switch_decision,
        }
      end

      private

        attr_reader :entrypoint, :draft

        def inventory
          @inventory ||=
            RuntimeGovernance::ExecutionTargetInventory.new(
              current_target: current_target,
              permission_mode: permission_mode,
              visible_only: true,
              relation: ExecutionTarget.all,
            )
        end

        def current_target
          return draft.proposed_execution_target if draft&.proposed_execution_target.present?
          return entrypoint.default_execution_target if entrypoint.respond_to?(:default_execution_target)
          return entrypoint.execution_target if entrypoint.respond_to?(:execution_target)

          nil
        end

        def permission_mode
          if draft.present?
            draft.permission_mode.to_s.presence || entrypoint_permission_mode
          else
            entrypoint_permission_mode
          end
        end

        def entrypoint_permission_mode
          return entrypoint.permission_mode.to_s if entrypoint.respond_to?(:permission_mode)

          "default"
        end

        def apply_proposal!(proposed_target)
          RuntimeGovernance::DraftGovernorResolver.apply!(
            draft: draft,
            entrypoint: entrypoint,
            selected_model_ref: draft.selected_model_ref,
            execution_target: proposed_target,
          )
          draft.save!
        end

        def ensure_draft!
          return if draft.present? && entrypoint.present?

          AgentCore::ValidationError.raise!(
            "execution_target.propose requires a draft-bound entrypoint.",
            code: "cybros.execution_targets.propose_requires_draft",
          )
        end
    end
  end
end
