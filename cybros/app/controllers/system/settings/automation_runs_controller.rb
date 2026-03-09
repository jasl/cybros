module System
  module Settings
    class AutomationRunsController < BaseController
      before_action :set_automation
      before_action :set_automation_run

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

        redirect_to system_settings_automation_path(@automation), notice: "Automation run approved."
      rescue ActiveRecord::RecordNotFound
        redirect_to system_settings_automation_path(@automation), alert: "Automation run is missing its parked draft."
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
        redirect_to system_settings_automation_path(@automation), notice: "Automation run rejected."
      rescue ActiveRecord::RecordNotFound
        redirect_to system_settings_automation_path(@automation), alert: "Automation run is missing its parked draft."
      rescue AgentCore::ValidationError => e
        if e.code == "cybros.run_drafts.approval_not_granted"
          redirect_to system_settings_automation_path(@automation), notice: "Automation run rejected."
        else
          redirect_to system_settings_automation_path(@automation), alert: e.message
        end
      end

      private

        def set_automation
          @automation = Automation.find(params[:automation_id])
        end

        def set_automation_run
          @automation_run = @automation.automation_runs.find(params[:id])
        end

        def parked_draft!
          raise ActiveRecord::RecordNotFound unless @automation_run.status == "awaiting_approval"

          draft_id = @automation_run.snapshot.dig("draft", "id").to_s.strip
          raise ActiveRecord::RecordNotFound if draft_id.blank?

          RunDraft.find(draft_id)
        end

        def approval_actor
          Current.identity&.email.to_s.presence || Current.user&.id.to_s
        end
    end
  end
end
