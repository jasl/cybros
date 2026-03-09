module System
  module Settings
    class AutomationsController < BaseController
      before_action :set_automation, only: :show

      def index
        @automations = Automation.includes(:agent_program, :execution_target, :conversation).order(created_at: :desc, id: :desc).to_a
        @latest_runs =
          AutomationRun.where(automation_id: @automations.map(&:id))
            .order(scheduled_for: :desc, id: :desc)
            .to_a
            .group_by(&:automation_id)
            .transform_values(&:first)
      end

      def show
        @automation_runs = @automation.automation_runs.includes(:conversation_run).order(scheduled_for: :desc, id: :desc)
      end

      private

        def set_automation
          @automation = Automation.includes(:agent_program, :execution_target, :conversation).find(params[:id])
        end
    end
  end
end
