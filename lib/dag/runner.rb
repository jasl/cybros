module DAG
  class Runner
    def self.run_node!(node_id)
      new(node_id: node_id).run_node!
    end

    def initialize(node_id:)
      @node_id = node_id
    end

    def run_node!
      node = DAG::Node.find_by(id: @node_id)
      return if node.nil?
      return unless node.running?

      conversation = node.conversation
      context = conversation.context_for(node.id)

      result = DAG.executor_registry.execute(node: node, context: context)
      conversation.with_graph_lock do
        conversation.transaction do
          apply_result(node, result)
          conversation.validate_leaf_invariant!
        end
      end
    rescue StandardError => error
      if node
        conversation = node.conversation
        conversation.with_graph_lock do
          conversation.transaction do
            apply_result(node, DAG::ExecutionResult.errored(error: "#{error.class}: #{error.message}"))
            conversation.validate_leaf_invariant!
          end
        end
      end
    ensure
      if node
        DAG::TickConversationJob.perform_later(node.conversation_id)
      end
    end

    private

      def apply_result(node, result)
        from_state = node.state
        transitioned =
          case result.state
          when DAG::Node::FINISHED
            node.mark_finished!(content: result.content, metadata: result.metadata)
          when DAG::Node::ERRORED
            node.mark_errored!(error: result.error || "errored", metadata: result.metadata)
          when DAG::Node::REJECTED
            node.mark_rejected!(reason: result.reason || "rejected", metadata: result.metadata)
          when DAG::Node::SKIPPED
            node.mark_skipped!(reason: result.reason, metadata: result.metadata)
          when DAG::Node::CANCELLED
            node.mark_cancelled!(reason: result.reason, metadata: result.metadata)
          else
            node.mark_errored!(error: "unknown_execution_result_state=#{result.state}")
          end

        if transitioned
          node.conversation.record_event!(
            event_type: "node_state_changed",
            subject: node,
            particulars: { "from" => from_state, "to" => node.state }
          )
        end
      end
  end
end
