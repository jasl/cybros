module Automations
  class ExecuteRunJob < ApplicationJob
    queue_as :default

    def perform(automation_run_id)
      automation_run = claim_queued_run!(automation_run_id)
      return if automation_run.nil?

      Automations::RunOrchestrator.start!(automation_run: automation_run)
    rescue Exception => error
      if automation_run.present?
        automation_run.reload
        if automation_run.status == "running"
          Automations::RunStateRecorder.failed!(automation_run: automation_run, error: error)
        end
      end
      raise
    end

    private

      def claim_queued_run!(automation_run_id)
        AutomationRun.transaction do
          automation_run = AutomationRun.lock.find_by(id: automation_run_id)
          next nil if automation_run.nil? || automation_run.status != "queued"

          automation_run.update!(
            status: "running",
            started_at: automation_run.started_at || Time.current.change(usec: 0),
          )
          automation_run
        end
      end
  end
end
