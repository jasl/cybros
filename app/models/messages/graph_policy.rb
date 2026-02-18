module Messages
  class GraphPolicy < DAG::GraphPolicies::Default
    def body_class_for_node_type(node_type)
      case node_type.to_s
      when DAG::Node::USER_MESSAGE
        Messages::UserMessage
      when DAG::Node::AGENT_MESSAGE
        Messages::AgentMessage
      when DAG::Node::TASK
        Messages::ToolCall
      when DAG::Node::SUMMARY
        Messages::Summary
      else
        super
      end
    end
  end
end
