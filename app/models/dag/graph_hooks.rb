module DAG
  class GraphHooks
    module EventTypes
      NODE_CREATED = "node_created"
      EDGE_CREATED = "edge_created"
      NODE_REPLACED = "node_replaced"
      SUBGRAPH_COMPRESSED = "subgraph_compressed"
      LEAF_INVARIANT_REPAIRED = "leaf_invariant_repaired"
      NODE_STATE_CHANGED = "node_state_changed"

      ALL = [
        NODE_CREATED,
        EDGE_CREATED,
        NODE_REPLACED,
        SUBGRAPH_COMPRESSED,
        LEAF_INVARIANT_REPAIRED,
        NODE_STATE_CHANGED,
      ].freeze
    end

    def record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})
      raise NotImplementedError, "#{self.class.name} must implement #record_event"
    end

    class Noop < GraphHooks
      def record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})
        _ = graph
        _ = event_type
        _ = subject_type
        _ = subject_id
        _ = particulars
      end
    end
  end
end
