module RunDrafts
  class ConversationTurnOrchestrator
    def self.enqueue!(conversation:, initiated_by_user:, selected_model_ref:, trigger_snapshot:, debug: {}, error: {})
      new(
        conversation: conversation,
        initiated_by_user: initiated_by_user,
        selected_model_ref: selected_model_ref,
        trigger_snapshot: trigger_snapshot,
        debug: debug,
        error: error,
      ).enqueue!
    end

    def initialize(conversation:, initiated_by_user:, selected_model_ref:, trigger_snapshot:, debug:, error:)
      @conversation = conversation
      @initiated_by_user = initiated_by_user
      @selected_model_ref = selected_model_ref
      @trigger_snapshot = trigger_snapshot
      @debug = debug
      @error = error
    end

    def enqueue!
      draft =
        RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
          conversation: conversation,
          initiated_by_user: initiated_by_user,
          selected_model_ref: selected_model_ref,
          trigger_snapshot: trigger_snapshot,
        )

      if draft.status.to_s == RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
        { draft: draft, conversation_run: nil }
      else
        {
          draft: draft,
          conversation_run: RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error),
        }
      end
    end

    private

      attr_reader :conversation, :initiated_by_user, :selected_model_ref, :trigger_snapshot, :debug, :error
  end
end
