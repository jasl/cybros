module RunDrafts
  class ApprovalResumeService
    def self.resume!(draft:, debug: {}, error: {})
      new(draft: draft, debug: debug, error: error).resume!
    end

    def initialize(draft:, debug:, error:)
      @draft = draft
      @debug = debug
      @error = error
    end

    def resume!
      approval_status = draft.approval_state["status"].to_s
      discard_if_terminal_non_approved!(approval_status)

      unless approval_status == "approved"
        AgentCore::ValidationError.raise!(
          "Run draft approval has not been granted.",
          code: "cybros.run_drafts.approval_not_granted",
          details: { run_draft_id: draft.id, approval_state: draft.approval_state },
        )
      end

      run = finalize_approved_draft!
      agent_node_for(draft)&.approve!
      run
    end

    private

      attr_reader :draft, :debug, :error

      def discard_if_terminal_non_approved!(approval_status)
        return if approval_status.blank? || approval_status == "approved" || approval_status == "not_required"
        return if pending_approval_status?(approval_status)

        RunDrafts::DiscardService.discard!(draft: draft, status: "discarded")
        agent_node_for(draft)&.deny_approval!(reason: terminal_reason(approval_status))
        sync_terminal_automation_execution!(approval_status)
      end

      def finalize_approved_draft!
        run = RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error)
        conversation = draft.bound_conversation
        if run.present? && conversation.present?
          Automations::ExecutionStateRecorder.running!(conversation: conversation, draft: draft.reload, conversation_run: run)
        elsif conversation.present?
          Automations::ExecutionStateRecorder.completed!(conversation: conversation, draft: draft.reload)
        end
        run
      rescue AgentCore::ValidationError => e
        handle_finalize_failure!(e)
        raise
      rescue StandardError => e
        record_failed_execution!(error: e)
        raise
      end

      def handle_finalize_failure!(error)
        case error.code
        when "cybros.run_drafts.stale"
          terminalize_approval!(status: "stale", reason: "binding_stale", timestamp_key: "stale_at")
          agent_node_for(draft)&.deny_approval!(reason: "binding_stale")
          record_failed_execution!(error: error)
        when "cybros.run_drafts.expired"
          terminalize_approval!(status: "expired", reason: "approval_expired", timestamp_key: "expired_at")
          agent_node_for(draft)&.deny_approval!(reason: "approval_expired")
          record_canceled_execution!
        end
      end

      def pending_approval_status?(approval_status)
        approval_status.start_with?("pending", "awaiting")
      end

      def terminal_reason(approval_status)
        reason = draft.approval_state["reason"].to_s.strip
        return reason if reason.present?
        return "approval_expired" if approval_status == "expired"

        approval_status
      end

      def terminalize_approval!(status:, reason:, timestamp_key:)
        draft.reload
        approval_state =
          draft.approval_state.merge(
            "status" => status,
            "reason" => reason,
            timestamp_key => Time.current.iso8601,
          )
        draft.update!(approval_state: approval_state)
      end

      def agent_node_for(draft)
        conversation = draft.bound_conversation
        return nil unless conversation.present?

        node_id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return nil if node_id.blank?

        conversation.root_graph.nodes.find_by(id: node_id)
      end

      def record_failed_execution!(error:)
        conversation = draft.bound_conversation
        return if conversation.blank?

        Automations::ExecutionStateRecorder.failed!(conversation: conversation, draft: draft.reload, error: error)
      end

      def record_canceled_execution!
        conversation = draft.bound_conversation
        return if conversation.blank?

        Automations::ExecutionStateRecorder.canceled!(conversation: conversation, draft: draft.reload)
      end

      def sync_terminal_automation_execution!(approval_status)
        conversation = draft.bound_conversation
        return if conversation.blank?

        case approval_status
        when "canceled"
          Automations::ExecutionStateRecorder.canceled!(conversation: conversation, draft: draft.reload)
        else
          Automations::ExecutionStateRecorder.rejected!(conversation: conversation, draft: draft.reload)
        end
      end
  end
end
