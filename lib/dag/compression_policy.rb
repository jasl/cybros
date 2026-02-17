module DAG
  class CompressionPolicy
    def eligible?(_graph)
      false
    end

    def pick_node_ids(_graph)
      []
    end

    class Null < CompressionPolicy
    end
  end
end
