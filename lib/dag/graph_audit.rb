module DAG
  class GraphAudit
    ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE = "active_edge_to_inactive_node"
    ISSUE_STALE_VISIBILITY_PATCH = "stale_visibility_patch"
    ISSUE_LEAF_INVARIANT_VIOLATION = "leaf_invariant_violation"
    ISSUE_STALE_RUNNING_NODE = "stale_running_node"

    DEFAULT_TYPES = [
      ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE,
      ISSUE_STALE_VISIBILITY_PATCH,
      ISSUE_LEAF_INVARIANT_VIOLATION,
      ISSUE_STALE_RUNNING_NODE,
    ].freeze

    def self.scan(graph:, types: DEFAULT_TYPES, now: Time.current)
      new(graph: graph, types: Array(types).map(&:to_s), now: now).scan
    end

    def self.repair!(graph:, types: DEFAULT_TYPES, now: Time.current)
      new(graph: graph, types: Array(types).map(&:to_s), now: now).repair!
    end

    def initialize(graph:, types:, now:)
      @graph = graph
      @types = types
      @now = now
    end

    def scan
      issues = []

      if @types.include?(ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE)
        active_edge_to_inactive_node_ids.each do |edge_id|
          issues << issue_hash(
            type: ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE,
            severity: "error",
            subject_type: "DAG::Edge",
            subject_id: edge_id,
            details: {}
          )
        end
      end

      if @types.include?(ISSUE_STALE_VISIBILITY_PATCH)
        stale_visibility_patch_ids.each do |patch_id|
          issues << issue_hash(
            type: ISSUE_STALE_VISIBILITY_PATCH,
            severity: "warn",
            subject_type: "DAG::NodeVisibilityPatch",
            subject_id: patch_id,
            details: {}
          )
        end
      end

      if @types.include?(ISSUE_LEAF_INVARIANT_VIOLATION)
        leaf_invariant_violations.each do |node_id|
          issues << issue_hash(
            type: ISSUE_LEAF_INVARIANT_VIOLATION,
            severity: "error",
            subject_type: "DAG::Node",
            subject_id: node_id,
            details: {}
          )
        end
      end

      if @types.include?(ISSUE_STALE_RUNNING_NODE)
        stale_running_node_ids.each do |node_id|
          issues << issue_hash(
            type: ISSUE_STALE_RUNNING_NODE,
            severity: "error",
            subject_type: "DAG::Node",
            subject_id: node_id,
            details: {}
          )
        end
      end

      issues
    end

    def repair!
      results = { "repaired" => {}, "now" => @now }

      @graph.with_graph_lock! do
        if @types.include?(ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE)
          edge_ids = active_edge_to_inactive_node_ids
          if edge_ids.any?
            @graph.edges.where(id: edge_ids).update_all(compressed_at: @now, updated_at: @now)
          end
          results["repaired"][ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE] = edge_ids.length
        end

        if @types.include?(ISSUE_STALE_VISIBILITY_PATCH)
          patch_ids = stale_visibility_patch_ids
          if patch_ids.any?
            DAG::NodeVisibilityPatch.where(id: patch_ids).delete_all
          end
          results["repaired"][ISSUE_STALE_VISIBILITY_PATCH] = patch_ids.length
        end

        if @types.include?(ISSUE_STALE_RUNNING_NODE)
          node_ids = DAG::RunningLeaseReclaimer.reclaim!(graph: @graph, now: @now)
          results["repaired"][ISSUE_STALE_RUNNING_NODE] = node_ids.length
        end

        if @types.include?(ISSUE_LEAF_INVARIANT_VIOLATION)
          created = @graph.validate_leaf_invariant!
          results["repaired"][ISSUE_LEAF_INVARIANT_VIOLATION] = created ? 1 : 0
        end
      end

      results
    end

    private

      def issue_hash(type:, severity:, subject_type:, subject_id:, details:)
        {
          "type" => type,
          "severity" => severity,
          "subject_type" => subject_type,
          "subject_id" => subject_id,
          "details" => details,
        }
      end

      def active_edge_to_inactive_node_ids
        @graph.edges.active
          .joins("JOIN dag_nodes from_nodes ON from_nodes.id = dag_edges.from_node_id")
          .joins("JOIN dag_nodes to_nodes ON to_nodes.id = dag_edges.to_node_id")
          .where("from_nodes.compressed_at IS NOT NULL OR to_nodes.compressed_at IS NOT NULL")
          .pluck(:id)
      end

      def stale_visibility_patch_ids
        DAG::NodeVisibilityPatch.where(graph_id: @graph.id)
          .joins("JOIN dag_nodes n ON n.id = dag_node_visibility_patches.node_id")
          .where("n.compressed_at IS NOT NULL")
          .pluck(:id)
      end

      def leaf_invariant_violations
        @graph.leaf_nodes.where(compressed_at: nil).pluck(:id).select do |node_id|
          node = @graph.nodes.find(node_id)
          !@graph.policy.leaf_valid?(node)
        end
      end

      def stale_running_node_ids
        @graph.nodes.active
          .where(state: DAG::Node::RUNNING)
          .where("lease_expires_at IS NOT NULL AND lease_expires_at < ?", @now)
          .pluck(:id)
      end
  end
end
