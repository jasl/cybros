module SubagentThreads
  class OwnerNoticePublisher
    class << self
      def publish_if_needed!(thread:, snapshot:)
        new(thread: thread, snapshot: snapshot).publish_if_needed!
      end
    end

    def initialize(thread:, snapshot:)
      @thread = thread
      @snapshot = snapshot.is_a?(Hash) ? snapshot.deep_stringify_keys : {}
    end

    def publish_if_needed!
      return nil unless publishable?

      task = nil
      notice_payload = snapshot.merge("operation" => "notice")

      graph.mutate!(turn_id: thread.owner_turn_id) do |m|
        task =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: owner_lane_id,
            turn_id: thread.owner_turn_id,
            metadata: {
              "authored_metadata" => {
                "leaf_terminal" => true,
              },
              "subagent_thread_id" => thread.id,
            },
            body_input: notice_body_input,
            body_output: {
              "result" => subagent_result(payload: notice_payload).to_h,
            },
          )

        anchor = owner_anchor_node
        m.create_edge(from_node: anchor, to_node: task, edge_type: DAG::Edge::SEQUENCE) if anchor.present?
      end

      thread.update!(owner_notified_at: Time.current)
      task
    end

    private

      attr_reader :thread, :snapshot

      def publishable?
        return false unless graph.present?
        return false unless owner_turn_active?
        return false if existing_notice.present?
        return false unless %w[failed stopped missing].include?(snapshot["status"].to_s)
        return false if thread.terminal_origin.to_s == "owner_action"

        terminal_at = thread.terminal_at
        notified_at = thread.owner_notified_at

        notified_at.blank? || terminal_at.present? && notified_at < terminal_at
      end

      def graph
        @graph ||= thread.owner_graph
      end

      def owner_lane_id
        owner_anchor_node&.lane_id || thread.owner_node&.lane_id || graph&.main_lane&.id
      end

      def owner_anchor_node
        @owner_anchor_node ||= graph&.nodes&.active&.find_by(id: thread.owner_node_id)
      end

      def owner_turn_active?
        graph.nodes.active.where(turn_id: thread.owner_turn_id, state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL]).exists?
      end

      def existing_notice
        graph.nodes.active
          .where(turn_id: thread.owner_turn_id, node_type: Messages::Task.node_type_key)
          .order(:id)
          .detect do |node|
            node.metadata["subagent_thread_id"].to_s == thread.id.to_s &&
              node.body_input["name"].to_s == "subagent_notice" &&
              node.updated_at >= (thread.terminal_at || Time.at(0))
          end
      rescue StandardError
        nil
      end

      def notice_body_input
        arguments = {
          "name" => thread.title,
          "subagent_id" => thread.id,
          "reason" => thread.terminal_reason.to_s.presence || snapshot.dig("error", "message").to_s.presence || snapshot["status"].to_s,
        }.compact

        {
          "name" => "subagent_notice",
          "requested_name" => "subagent_notice",
          "resolved_name" => "subagent_notice",
          "tool_call_id" => "subagent_notice:#{thread.id}:#{(thread.terminal_at || Time.current).to_i}",
          "arguments" => arguments,
          "arguments_summary" => JSON.generate(arguments),
        }
      end

      def subagent_result(payload:)
        AgentCore::Resources::Tools::ToolResult.success(
          text: JSON.generate(payload),
          metadata: { subagent: payload },
        )
      end
  end
end
