module RunDrafts
  class ApprovalExpiryService
    def self.expire!(draft:)
      new(draft: draft).expire!
    end

    def initialize(draft:)
      @draft = draft
    end

    def expire!
      return draft unless expirable?

      approval_state =
        draft.approval_state.merge(
          "status" => "expired",
          "reason" => "approval_expired",
          "expired_at" => Time.current.iso8601,
        )
      RunDrafts::DiscardService.discard!(draft: draft, status: "expired", approval_state: approval_state)
      agent_node_for(draft)&.deny_approval!(reason: "approval_expired")
      conversation = draft.bound_conversation
      Automations::ExecutionStateRecorder.canceled!(conversation: conversation, draft: draft.reload) if conversation.present?
      draft.reload
    end

    private

      attr_reader :draft

      def expirable?
        draft.status == RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS &&
          draft.expires_at.present? &&
          draft.expires_at <= Time.current &&
          pending_approval_status?(draft.approval_state["status"])
      end

      def pending_approval_status?(status)
        normalized = status.to_s
        normalized.blank? || normalized.start_with?("pending", "awaiting")
      end

      def agent_node_for(draft)
        conversation = draft.bound_conversation
        return nil unless conversation.present?

        node_id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return nil if node_id.blank?

        conversation.root_graph.nodes.find_by(id: node_id)
      end
  end
end
