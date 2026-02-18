module DAG
  class Runner
    EXECUTION_LEASE_SECONDS = 2.hours

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

      graph = node.graph
      return if node.lease_expires_at.present? && node.lease_expires_at < Time.current

      return unless refresh_running_lease!(node)

      context = graph.context_for(node.id)

      result = DAG.executor_registry.execute(node: node, context: context)
      graph.with_graph_lock! do
        apply_result(node, result)
        DAG::FailurePropagation.propagate!(graph: graph)
        graph.validate_leaf_invariant!
      end
    rescue StandardError => error
      if node
        graph = node.graph
        graph.with_graph_lock! do
          apply_result(node, DAG::ExecutionResult.errored(error: "#{error.class}: #{error.message}"))
          DAG::FailurePropagation.propagate!(graph: graph)
          graph.validate_leaf_invariant!
        end
      end
    ensure
      DAG::TickGraphJob.perform_later(node.graph_id) if node
    end

    private

      def refresh_running_lease!(node)
        now = Time.current
        started_at = node.started_at || now
        lease_expires_at = now + EXECUTION_LEASE_SECONDS

        affected_rows =
          DAG::Node.where(id: node.id, state: DAG::Node::RUNNING, compressed_at: nil).update_all(
            started_at: started_at,
            heartbeat_at: now,
            lease_expires_at: lease_expires_at,
            updated_at: now
          )

        return false unless affected_rows == 1

        node.reload
        true
      end

      def apply_result(node, result)
        from_state = node.state
        metadata = normalize_hook_metadata(result.metadata)
        if result.usage.is_a?(Hash) && result.usage.present?
          metadata["usage"] = result.usage.deep_stringify_keys
        end

        transitioned =
          case result.state
          when DAG::Node::FINISHED
            node.mark_finished!(content: result.content, payload: result.payload, metadata: metadata)
          when DAG::Node::ERRORED
            node.mark_errored!(error: result.error || "errored", metadata: metadata)
          when DAG::Node::REJECTED
            node.mark_rejected!(reason: result.reason || "rejected", metadata: metadata)
          when DAG::Node::SKIPPED
            node.mark_errored!(
              error: "invalid_execution_result_state=skipped_for_running_node",
              metadata: metadata.merge("reason" => result.reason)
            )
          when DAG::Node::CANCELLED
            node.mark_cancelled!(reason: result.reason, metadata: metadata)
          else
            node.mark_errored!(error: "unknown_execution_result_state=#{result.state}", metadata: metadata)
          end

        if transitioned
          node.graph.emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
            subject: node,
            particulars: { "from" => from_state, "to" => node.state }
          )
        end
      end

      def normalize_hook_metadata(metadata)
        if metadata.is_a?(Hash)
          metadata.deep_stringify_keys
        else
          {}
        end
      end
  end
end
