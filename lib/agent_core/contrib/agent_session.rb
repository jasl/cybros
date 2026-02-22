# frozen_string_literal: true

require "securerandom"

module AgentCore
  module Contrib
    # Minimal DAG-first session wrapper for Rails console/tests.
    #
    # This replaces the old PromptRunner-based AgentSession. It intentionally
    # does not implement continuation/resume APIs; pause/resume is represented
    # by DAG `task` nodes in `awaiting_approval`.
    class AgentSession
      def initialize(graph:, lane_id: nil)
        @graph = graph
        @lane_id = lane_id
      end

      attr_reader :graph, :lane_id

      def chat(user_content:, agent_metadata: {})
        turn_id = SecureRandom.uuid

        graph.mutate!(turn_id: turn_id) do |m|
          user =
            m.create_node(
              node_type: Messages::UserMessage.node_type_key,
              state: ::DAG::Node::FINISHED,
              content: user_content,
              metadata: {},
              lane_id: effective_lane_id
            )

          agent =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: ::DAG::Node::PENDING,
              metadata: agent_metadata,
              lane_id: effective_lane_id,
            )

          m.create_edge(from_node: user, to_node: agent, edge_type: ::DAG::Edge::SEQUENCE)
        end

        run_until_idle!
      end

      def run_until_idle!(limit: 100)
        limit = Integer(limit)
        raise ValidationError, "limit must be > 0" if limit <= 0

        runs = 0

        loop do
          claimed = ::DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 20, claimed_by: "agent_session")
          break if claimed.empty?

          claimed.each do |node|
            ::DAG::Runner.run_node!(node.id)
            runs += 1
            raise "AgentSession run limit exceeded" if runs >= limit
          end
        end

        graph.leaf_nodes.where(lane_id: effective_lane_id).order(:id).last
      end

      private

        def effective_lane_id
          lane_id || graph.main_lane.id
        end
    end
  end
end
