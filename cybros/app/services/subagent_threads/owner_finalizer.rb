module SubagentThreads
  class OwnerFinalizer
    class << self
      def freeze_active_threads!(owner_turn:, freeze_reason:)
        now = Time.current

        SubagentThread.active_control.where(owner_turn_id: owner_turn.id).find_each do |thread|
          stop_nonterminal_child_nodes!(thread.child_graph, reason: freeze_reason)
          cancel_nonterminal_tasks!(thread.child_conversation, reason: freeze_reason)

          snapshot =
            SubagentThreads::ControlPlane.refresh_snapshot!(
              thread: thread,
              limit_turns: SubagentThreads::ControlPlane::DEFAULT_LIMIT_TURNS,
              operation: "freeze",
            )

          thread.mark_frozen!(freeze_reason: freeze_reason, snapshot: snapshot, at: now)
        end
      end

      private

        def stop_nonterminal_child_nodes!(graph, reason:)
          return if graph.nil?

          graph.nodes.active.where(state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL]).find_each do |node|
            node.stop!(reason: reason.to_s)
          end
        end

        def cancel_nonterminal_tasks!(conversation, reason:)
          return if conversation.nil?

          conversation.turn_internal_tasks.nonterminal.update_all(
            status: "canceled",
            canceled_reason: reason.to_s,
            updated_at: Time.current,
          )
        end
    end
  end
end
