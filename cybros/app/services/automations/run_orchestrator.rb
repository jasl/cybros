module Automations
  class RunOrchestrator
    def self.start!(automation_run:, debug: {}, error: {})
      new(automation_run: automation_run, debug: debug, error: error).start!
    end

    def initialize(automation_run:, debug:, error:)
      @automation_run = automation_run
      @debug = debug
      @error = error
    end

    def start!
      draft = RunDrafts::AutomationPlanningService.open_and_prepare!(automation_run: automation_run)

      if draft.status.to_s == RunDrafts::AutomationPlanningService::AWAITING_APPROVAL_STATUS
        { draft: draft, conversation_run: nil }
      else
        {
          draft: draft,
          conversation_run: RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error),
        }
      end
    end

    private

      attr_reader :automation_run, :debug, :error
  end
end
