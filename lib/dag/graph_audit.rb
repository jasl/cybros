module DAG
  class GraphAudit
    ISSUE_MISCONFIGURED_GRAPH = "misconfigured_graph"
    ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE = "active_edge_to_inactive_node"
    ISSUE_STALE_VISIBILITY_PATCH = "stale_visibility_patch"
    ISSUE_LEAF_INVARIANT_VIOLATION = "leaf_invariant_violation"
    ISSUE_STALE_RUNNING_NODE = "stale_running_node"

    DEFAULT_TYPES = [
      ISSUE_MISCONFIGURED_GRAPH,
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

      if @types.include?(ISSUE_MISCONFIGURED_GRAPH)
        issue = misconfigured_graph_issue
        issues << issue if issue
      end

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
        if @types.include?(ISSUE_MISCONFIGURED_GRAPH)
          results["repaired"][ISSUE_MISCONFIGURED_GRAPH] = 0
        end

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

      def misconfigured_graph_issue
        problems = misconfigured_graph_problems
        return nil if problems.empty?

        severity = problems.any? { |problem| problem["severity"] == "error" } ? "error" : "warn"

        namespace = nil
        attachable = @graph.attachable
        if attachable&.respond_to?(:dag_node_body_namespace)
          begin
            ns = attachable.dag_node_body_namespace
            namespace = ns.name if ns.is_a?(Module)
          rescue StandardError
            namespace = nil
          end
        end

        issue_hash(
          type: ISSUE_MISCONFIGURED_GRAPH,
          severity: severity,
          subject_type: "DAG::Graph",
          subject_id: @graph.id,
          details: {
            "attachable_type" => @graph.attachable_type,
            "attachable_id" => @graph.attachable_id,
            "namespace" => namespace,
            "problems" => problems,
          }
        )
      end

      def misconfigured_graph_problems
        problems = []

        attachable = @graph.attachable
        if attachable.nil?
          problems << problem_hash(
            code: "attachable_missing",
            severity: "error",
            message: "graph.attachable is missing",
            extras: {}
          )
          return problems
        end

        unless attachable.respond_to?(:dag_node_body_namespace)
          problems << problem_hash(
            code: "dag_node_body_namespace_missing",
            severity: "error",
            message: "attachable must define dag_node_body_namespace",
            extras: { "attachable_class" => attachable.class.name }
          )
          return problems
        end

        namespace =
          begin
            attachable.dag_node_body_namespace
          rescue StandardError => error
            error
          end

        unless namespace.is_a?(Module)
          problems << problem_hash(
            code: "dag_node_body_namespace_not_module",
            severity: "error",
            message: "dag_node_body_namespace must return a Module",
            extras: {
              "returned_class" => namespace.class.name,
              "returned_inspect" => namespace.inspect,
            }
          )
          return problems
        end

        body_classes = node_body_classes(namespace)
        if body_classes.empty?
          problems << problem_hash(
            code: "node_body_namespace_has_no_bodies",
            severity: "error",
            message: "dag_node_body_namespace has no NodeBody classes",
            extras: { "namespace" => namespace.name }
          )
          return problems
        end

        problems.concat(node_type_key_mismatch_problems(body_classes))
        problems.concat(node_type_key_collision_problems(body_classes))
        problems.concat(default_leaf_repair_problems(body_classes))
        problems.concat(created_content_destination_problems(body_classes))
        problems.concat(transcript_recent_turn_support_problems(body_classes))

        problems
      end

      def node_body_classes(namespace)
        namespace.constants(false).filter_map do |constant_name|
          constant = namespace.const_get(constant_name)
          next unless constant.is_a?(Class)
          next unless constant < DAG::NodeBody

          constant
        rescue NameError
          nil
        end
      end

      def node_type_key_mismatch_problems(body_classes)
        problems = []

        body_classes.each do |body_class|
          expected = body_class.name.demodulize.underscore
          actual = body_class.node_type_key.to_s

          next if actual == expected

          problems << problem_hash(
            code: "node_type_key_mismatch",
            severity: "error",
            message: "NodeBody node_type_key must match class name for convention mapping",
            extras: {
              "class" => body_class.name,
              "node_type_key" => actual,
              "expected" => expected,
            }
          )
        end

        problems
      end

      def node_type_key_collision_problems(body_classes)
        by_key = Hash.new { |hash, key| hash[key] = [] }

        body_classes.each do |body_class|
          key = body_class.node_type_key.to_s
          by_key[key] << body_class.name
        end

        by_key.filter_map do |key, class_names|
          next if key.present? && class_names.length == 1

          problem_hash(
            code: "node_type_key_collision",
            severity: "error",
            message: "NodeBody node_type_key must be present and unique within the namespace",
            extras: {
              "key" => key,
              "classes" => class_names.sort,
            }
          )
        end
      end

      def default_leaf_repair_problems(body_classes)
        repair_bodies = body_classes.select(&:default_leaf_repair?)
        if repair_bodies.length != 1
          return [
            problem_hash(
              code: "default_leaf_repair_not_unique",
              severity: "error",
              message: "expected exactly 1 NodeBody with default_leaf_repair?==true",
              extras: { "classes" => repair_bodies.map(&:name).sort }
            ),
          ]
        end

        body_class = repair_bodies.first
        problems = []

        unless body_class.executable?
          problems << problem_hash(
            code: "default_leaf_repair_not_executable",
            severity: "error",
            message: "default leaf repair NodeBody must be executable",
            extras: { "class" => body_class.name }
          )
        end

        unless body_class.leaf_terminal?
          problems << problem_hash(
            code: "default_leaf_repair_not_leaf_terminal",
            severity: "error",
            message: "default leaf repair NodeBody must be leaf_terminal",
            extras: { "class" => body_class.name }
          )
        end

        problems
      end

      def created_content_destination_problems(body_classes)
        body_classes.filter_map do |body_class|
          destination = body_class.created_content_destination

          valid =
            destination.is_a?(Array) &&
              destination.length == 2 &&
              begin
                channel = destination[0]
                key = destination[1]
                channel_sym = channel.to_sym
                channel_sym.in?([:input, :output]) && key.to_s.present?
              rescue StandardError
                false
              end

          next if valid

          problem_hash(
            code: "invalid_created_content_destination",
            severity: "error",
            message: "NodeBody created_content_destination must be [:input|:output, non-empty key]",
            extras: {
              "class" => body_class.name,
              "destination" => destination,
            }
          )
        rescue StandardError => error
          problem_hash(
            code: "invalid_created_content_destination",
            severity: "error",
            message: "NodeBody created_content_destination raised an error",
            extras: {
              "class" => body_class.name,
              "error" => "#{error.class}: #{error.message}",
            }
          )
        end
      end

      def transcript_recent_turn_support_problems(body_classes)
        problems = []

        if body_classes.none?(&:turn_anchor?)
          problems << problem_hash(
            code: "missing_turn_anchor_node_type",
            severity: "warn",
            message: "no NodeBody classes have turn_anchor?==true (transcript_recent_turns will always be empty)",
            extras: {}
          )
        end

        if body_classes.none?(&:transcript_candidate?)
          problems << problem_hash(
            code: "missing_transcript_candidate_node_type",
            severity: "warn",
            message: "no NodeBody classes have transcript_candidate?==true (transcript_recent_turns will always be empty)",
            extras: {}
          )
        end

        problems
      end

      def issue_hash(type:, severity:, subject_type:, subject_id:, details:)
        {
          "type" => type,
          "severity" => severity,
          "subject_type" => subject_type,
          "subject_id" => subject_id,
          "details" => details,
        }
      end

      def problem_hash(code:, severity:, message:, extras:)
        {
          "code" => code,
          "severity" => severity,
          "message" => message,
          "extras" => extras,
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
          !@graph.leaf_valid?(node)
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
