module System
  module Settings
    class AutomationExecutionsController < BaseController
      before_action :set_automation
      before_action :set_execution_conversation

      def approve
        draft = parked_draft!
        draft.update!(
          approval_state:
            draft.approval_state.merge(
              "status" => "approved",
              "approved_at" => Time.current.iso8601,
              "approved_by" => approval_actor,
            ),
        )

        conversation_run = RunDrafts::ApprovalResumeService.resume!(draft: draft)
        conversation_run&.conversation&.root_graph&.kick!

        redirect_to system_settings_automation_path(@automation), notice: "Automation execution approved."
      rescue ActiveRecord::RecordNotFound
        redirect_to system_settings_automation_path(@automation), alert: "Automation execution is missing its parked draft."
      rescue AgentCore::ValidationError => e
        redirect_to system_settings_automation_path(@automation), alert: e.message
      end

      def reject
        draft = parked_draft!
        draft.update!(
          approval_state:
            draft.approval_state.merge(
              "status" => "rejected",
              "reason" => "operator_denied",
              "rejected_at" => Time.current.iso8601,
              "rejected_by" => approval_actor,
            ),
        )

        RunDrafts::ApprovalResumeService.resume!(draft: draft)
        redirect_to system_settings_automation_path(@automation), notice: "Automation execution rejected."
      rescue ActiveRecord::RecordNotFound
        redirect_to system_settings_automation_path(@automation), alert: "Automation execution is missing its parked draft."
      rescue AgentCore::ValidationError => e
        if e.code == "cybros.run_drafts.approval_not_granted"
          redirect_to system_settings_automation_path(@automation), notice: "Automation execution rejected."
        else
          redirect_to system_settings_automation_path(@automation), alert: e.message
        end
      end

      private

        def set_automation
          @automation = Automation.find(params[:automation_id])
        end

        def set_execution_conversation
          @execution_conversation = @automation.conversations.find(params[:id])
        end

        def parked_draft!
          draft =
            @execution_conversation
              .run_drafts
              .where(status: RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS)
              .order(created_at: :desc, id: :desc)
              .first

          raise ActiveRecord::RecordNotFound if draft.blank?

          draft
        end

        def approval_actor
          Current.identity&.email.to_s.presence || Current.user&.id.to_s
        end
    end
  end
end
