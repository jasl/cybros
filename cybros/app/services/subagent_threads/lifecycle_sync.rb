module SubagentThreads
  class LifecycleSync
    DEFAULT_LIMIT_TURNS = 10

    class << self
      def sync_from_node!(node:)
        return if node.blank?

        sync_child_thread_from_node!(node)
        freeze_owner_threads_if_needed!(node)
      end

      private

        def sync_child_thread_from_node!(node)
          thread = SubagentThread.find_by(child_graph_id: node.graph_id)
          return if thread.nil?

          snapshot = ControlPlane.refresh_snapshot!(thread: thread, limit_turns: DEFAULT_LIMIT_TURNS, operation: "sync")
          return if Current.subagent_owner_proxy_thread_id.to_s == thread.id.to_s
          return unless %w[failed stopped missing].include?(snapshot["status"].to_s)
          return unless thread.active?

          terminal_reason =
            node.metadata["error"].to_s.presence ||
              node.metadata["reason"].to_s.presence ||
              snapshot.dig("error", "message").to_s.presence ||
              snapshot["status"].to_s

          thread.update!(
            terminal_origin: "child_runtime",
            terminal_reason: terminal_reason,
            terminal_at: Time.current,
            last_error_snapshot: snapshot,
          )

          OwnerNoticePublisher.publish_if_needed!(thread: thread, snapshot: snapshot)
        end

        def freeze_owner_threads_if_needed!(node)
          threads = SubagentThread.where(owner_graph_id: node.graph_id, owner_turn_id: node.turn_id, status: "active")
          return if threads.empty?
          return if owner_turn_active?(graph: node.graph, turn_id: node.turn_id)

          OwnerFinalizer.freeze_active_threads!(
            owner_turn: threads.first.owner_turn,
            freeze_reason: "owner_turn_finished",
          )
        end

        def owner_turn_active?(graph:, turn_id:)
          graph.nodes.active.where(turn_id: turn_id, state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL]).exists?
        end
    end
  end
end
