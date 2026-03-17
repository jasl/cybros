module RunDrafts
  class ConversationTurnOrchestrator
    def self.enqueue!(conversation:, initiated_by_user:, selected_model_ref:, permission_mode: nil, trigger_snapshot:, debug: {}, error: {})
      new(
        conversation: conversation,
        initiated_by_user: initiated_by_user,
        selected_model_ref: selected_model_ref,
        permission_mode: permission_mode,
        trigger_snapshot: trigger_snapshot,
        debug: debug,
        error: error,
      ).enqueue!
    end

    def initialize(conversation:, initiated_by_user:, selected_model_ref:, permission_mode:, trigger_snapshot:, debug:, error:)
      @conversation = conversation
      @initiated_by_user = initiated_by_user
      @selected_model_ref = selected_model_ref
      @permission_mode = permission_mode.to_s
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
          permission_mode: permission_mode,
          trigger_snapshot: trigger_snapshot,
        )

      if draft.status.to_s == RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
        park_agent_node_for_approval!(draft)
        { draft: draft, conversation_run: nil }
      elsif draft.status.to_s == "discarded"
        { draft: draft, conversation_run: nil }
      else
        {
          draft: draft,
          conversation_run: RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error),
        }
      end
    end

    private

      attr_reader :conversation, :initiated_by_user, :selected_model_ref, :permission_mode, :trigger_snapshot, :debug, :error

      def park_agent_node_for_approval!(draft)
        agent_node_for(draft)&.park_for_approval!
      end

      def agent_node_for(draft)
        node_id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return nil if node_id.blank?

        conversation.root_graph.nodes.find_by(id: node_id)
      end
  end
end
