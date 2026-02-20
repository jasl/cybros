module DAG
  class GraphHooks
    module EventTypes
      NODE_CREATED = "node_created"
      EDGE_CREATED = "edge_created"
      NODE_REPLACED = "node_replaced"
      LANE_COMPRESSED = "lane_compressed"
      LEAF_INVARIANT_REPAIRED = "leaf_invariant_repaired"
      NODE_STATE_CHANGED = "node_state_changed"
      NODE_VISIBILITY_CHANGE_REQUESTED = "node_visibility_change_requested"
      NODE_VISIBILITY_CHANGED = "node_visibility_changed"
      NODE_VISIBILITY_PATCH_DROPPED = "node_visibility_patch_dropped"

      ALL = [
        NODE_CREATED,
        EDGE_CREATED,
        NODE_REPLACED,
        LANE_COMPRESSED,
        LEAF_INVARIANT_REPAIRED,
        NODE_STATE_CHANGED,
        NODE_VISIBILITY_CHANGE_REQUESTED,
        NODE_VISIBILITY_CHANGED,
        NODE_VISIBILITY_PATCH_DROPPED,
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

    NOOP = Noop.new.freeze
  end
end
