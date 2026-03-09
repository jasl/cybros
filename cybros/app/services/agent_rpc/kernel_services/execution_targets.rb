module AgentRPC
  module KernelServices
    class ExecutionTargets
      def self.list(entrypoint:, draft: nil)
        new(entrypoint: entrypoint, draft: draft).list
      end

      def self.get(entrypoint:, execution_target_id:, draft: nil)
        new(entrypoint: entrypoint, draft: draft).get(execution_target_id:)
      end

      def self.propose!(draft:, execution_target_id:)
        new(entrypoint: resolve_entrypoint_for(draft), draft: draft).propose!(execution_target_id:)
      end

      def self.resolve_entrypoint_for(draft)
        return draft.conversation if draft.respond_to?(:conversation) && draft.conversation.present?

        nil
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

        if %w[allow confirm].include?(switch_decision.fetch("decision"))
          apply_proposal!(proposed_target, switch_decision: switch_decision)
        end

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

        def apply_proposal!(proposed_target, switch_decision:)
          resolved =
            RuntimeGovernance::DraftGovernorResolver.resolve!(
              entrypoint: entrypoint,
              selected_model_ref: draft.selected_model_ref,
              execution_target: proposed_target,
            )
          draft.assign_attributes(
            provider_credential: resolved.fetch(:provider_credential),
            proposed_execution_target: resolved.fetch(:proposed_execution_target),
            selected_model_ref: resolved.fetch(:selected_model_ref),
            runtime_governors: resolved.fetch(:runtime_governors),
          )
          if switch_decision.fetch("decision") == "confirm"
            draft.status = RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
            draft.approval_state = {
              "status" => "pending_confirmation",
              "reason" => "target_switch",
              "proposed_execution_target_id" => proposed_target.id,
            }
          end
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
