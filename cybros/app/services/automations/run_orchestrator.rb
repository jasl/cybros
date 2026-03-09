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
      draft = nil
      conversation_run = nil

      draft = RunDrafts::AutomationPlanningService.open_and_prepare!(automation_run: automation_run)

      if draft.status.to_s == RunDrafts::AutomationPlanningService::AWAITING_APPROVAL_STATUS
        mark_bound_agent_node_awaiting_approval!(draft)
        Automations::RunStateRecorder.awaiting_approval!(automation_run: automation_run, draft: draft)
        return { draft: draft, conversation_run: nil }
      end

      conversation_run = RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error)
      recorder_run = automation_run.reload
      recorder_draft = draft.reload
      if conversation_run.present?
        Automations::RunStateRecorder.running!(automation_run: recorder_run, draft: recorder_draft)
      else
        Automations::RunStateRecorder.completed!(automation_run: recorder_run, draft: recorder_draft)
      end
      conversation_run&.conversation&.root_graph&.kick!

      {
        draft: draft,
        conversation_run: conversation_run,
      }
    rescue StandardError => e
      Automations::RunStateRecorder.failed!(automation_run: automation_run, draft: draft, error: e)
      raise
    end

    private

      attr_reader :automation_run, :debug, :error

      def mark_bound_agent_node_awaiting_approval!(draft)
        conversation = draft.bound_conversation
        return unless conversation.present?

        node_id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return if node_id.empty?

        conversation.root_graph.nodes.find_by(id: node_id)&.park_for_approval!
      end
  end
end
