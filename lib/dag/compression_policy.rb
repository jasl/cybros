module DAG
  class CompressionPolicy
    def eligible?(_conversation)
      false
    end

    def pick_node_ids(_conversation)
      []
    end

    class Null < CompressionPolicy
    end
  end
end
