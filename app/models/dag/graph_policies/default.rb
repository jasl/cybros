module DAG
  module GraphPolicies
    class Default < DAG::GraphPolicy
      def body_class_for_node_type(node_type)
        case node_type.to_s
        when DAG::Node::USER_MESSAGE
          ::Messages::UserMessage
        when DAG::Node::AGENT_MESSAGE
          ::Messages::AgentMessage
        when DAG::Node::TASK
          ::Messages::ToolCall
        when DAG::Node::SUMMARY
          ::Messages::Summary
        else
          DAG::NodeBody
        end
      end

      def leaf_valid?(node)
        return true if node.node_type == DAG::Node::AGENT_MESSAGE

        node.pending? || node.running?
      end

      def leaf_repair_node_attributes(_leaf)
        {
          node_type: DAG::Node::AGENT_MESSAGE,
          state: DAG::Node::PENDING,
          metadata: { "generated_by" => "leaf_invariant" },
        }
      end

      def leaf_repair_edge_attributes(_leaf, _repaired_node)
        {
          edge_type: DAG::Edge::SEQUENCE,
          metadata: { "generated_by" => "leaf_invariant" },
        }
      end
    end
  end
end
