module DAG
  class GraphPolicy
    def body_class_for_node_type(_node_type)
      raise NotImplementedError, "#{self.class.name} must implement #body_class_for_node_type"
    end

    def leaf_valid?(_node)
      raise NotImplementedError, "#{self.class.name} must implement #leaf_valid?"
    end

    def leaf_repair_node_attributes(_leaf)
      raise NotImplementedError, "#{self.class.name} must implement #leaf_repair_node_attributes"
    end

    def leaf_repair_edge_attributes(_leaf, _repaired_node)
      raise NotImplementedError, "#{self.class.name} must implement #leaf_repair_edge_attributes"
    end

    def transcript_include?(context_node_hash)
      node_type = context_node_hash["node_type"].to_s

      case node_type
      when DAG::Node::USER_MESSAGE
        true
      when DAG::Node::AGENT_MESSAGE
        state = context_node_hash["state"].to_s
        preview_content = context_node_hash.dig("payload", "output_preview", "content").to_s
        metadata = context_node_hash["metadata"].is_a?(Hash) ? context_node_hash["metadata"] : {}
        transcript_visible = metadata["transcript_visible"] == true

        state.in?([DAG::Node::PENDING, DAG::Node::RUNNING]) || preview_content.present? || transcript_visible
      else
        false
      end
    end

    def transcript_preview_override(context_node_hash)
      return nil unless context_node_hash["node_type"].to_s == DAG::Node::AGENT_MESSAGE

      metadata = context_node_hash["metadata"].is_a?(Hash) ? context_node_hash["metadata"] : {}
      preview = metadata["transcript_preview"]
      return nil unless preview.is_a?(String) && preview.present?

      preview.truncate(2000)
    end

    def visibility_mutation_allowed?(node:, graph:)
      visibility_mutation_error(node: node, graph: graph).nil?
    end

    def visibility_mutation_error(node:, graph:)
      return "can only change visibility for terminal nodes" unless node.terminal?
      return "cannot change visibility while graph has running nodes" if graph.nodes.active.where(state: DAG::Node::RUNNING).exists?

      nil
    end

    def claim_lease_seconds_for(node)
      _ = node
      30.minutes
    end

    def execution_lease_seconds_for(node)
      _ = node
      2.hours
    end
  end
end
