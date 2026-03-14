module System
  module Settings
    class AutomationsController < BaseController
      before_action :set_automation, only: :show
      helper_method :execution_status_label, :execution_approval_status, :execution_approval_reason

      def index
        @automations = Automation.includes(:agent).order(created_at: :desc, id: :desc).to_a
        executions =
          Conversation.where(automation_id: @automations.map(&:id))
            .includes(:run_drafts, :conversation_runs)
            .order(automation_triggered_at: :desc, id: :desc)
            .to_a

        @latest_executions =
          executions
            .group_by(&:automation_id)
            .transform_values { |rows| rows.first }
      end

      def show
        @execution_conversations =
          @automation.conversations
            .includes(:run_drafts, :conversation_runs)
            .order(automation_triggered_at: :desc, id: :desc)
      end

      private

        def set_automation
          @automation = Automation.includes(:agent).find(params[:id])
        end

        def execution_status_label(conversation)
          draft = active_awaiting_approval_draft(conversation)
          return "awaiting_approval" if draft.present?

          run = latest_conversation_run(conversation)
          return normalize_run_state(run.runtime_state) if run.present?

          conversation.metadata.dig("automation_execution", "status").to_s.presence || "queued"
        end

        def execution_approval_status(conversation)
          draft = active_awaiting_approval_draft(conversation)
          return "not_required" if draft.blank?

          draft.approval_state["status"].presence || "pending_confirmation"
        end

        def execution_approval_reason(conversation)
          active_awaiting_approval_draft(conversation)&.approval_state&.fetch("reason", nil)
        end

        def active_awaiting_approval_draft(conversation)
          drafts = conversation.run_drafts.sort_by { |draft| [draft.created_at, draft.id] }.reverse
          drafts.find { |draft| draft.status == RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS }
        end

        def latest_conversation_run(conversation)
          conversation.conversation_runs.max_by { |run| [run.created_at, run.id] }
        end

        def normalize_run_state(state)
          return "completed" if state.to_s == "succeeded"

          state.to_s
        end
    end
  end
end
