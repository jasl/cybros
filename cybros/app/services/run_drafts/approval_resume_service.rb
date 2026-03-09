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
      unless draft.approval_state["status"].to_s == "approved"
        AgentCore::ValidationError.raise!(
          "Run draft approval has not been granted.",
          code: "cybros.run_drafts.approval_not_granted",
          details: { run_draft_id: draft.id, approval_state: draft.approval_state },
        )
      end

      run = RunDrafts::FinalizeService.finalize!(draft: draft, debug: debug, error: error)
      agent_node_for(draft)&.approve!
      run
    end

    private

      attr_reader :draft, :debug, :error

      def agent_node_for(draft)
        return nil unless draft.conversation.present?

        node_id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return nil if node_id.blank?

        draft.conversation.root_graph.nodes.find_by(id: node_id)
      end
  end
end
