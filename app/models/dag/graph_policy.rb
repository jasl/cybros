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
  end
end
