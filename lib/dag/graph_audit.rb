module DAG
  class GraphAudit
    ISSUE_MISCONFIGURED_GRAPH = "misconfigured_graph"
    ISSUE_CYCLE_DETECTED = "cycle_detected"
    ISSUE_TOPOLOGICAL_SORT_FAILED = "toposort_failed"
    ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE = "active_edge_to_inactive_node"
    ISSUE_STALE_VISIBILITY_PATCH = "stale_visibility_patch"
    ISSUE_LEAF_INVARIANT_VIOLATION = "leaf_invariant_violation"
    ISSUE_STALE_RUNNING_NODE = "stale_running_node"
    ISSUE_UNKNOWN_NODE_TYPE = "unknown_node_type"
    ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY = "node_type_maps_to_non_node_body"
    ISSUE_NODE_BODY_DRIFT = "node_body_drift"

    DEFAULT_TYPES = [
      ISSUE_MISCONFIGURED_GRAPH,
      ISSUE_CYCLE_DETECTED,
      ISSUE_TOPOLOGICAL_SORT_FAILED,
      ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE,
      ISSUE_STALE_VISIBILITY_PATCH,
      ISSUE_LEAF_INVARIANT_VIOLATION,
      ISSUE_STALE_RUNNING_NODE,
      ISSUE_UNKNOWN_NODE_TYPE,
      ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY,
      ISSUE_NODE_BODY_DRIFT,
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

      if @types.include?(ISSUE_CYCLE_DETECTED) || @types.include?(ISSUE_TOPOLOGICAL_SORT_FAILED)
        issue = cycle_or_toposort_failed_issue
        issues << issue if issue && @types.include?(issue.fetch(:type))
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

      if @types.include?(ISSUE_UNKNOWN_NODE_TYPE) ||
          @types.include?(ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY) ||
          @types.include?(ISSUE_NODE_BODY_DRIFT)
        namespace = node_body_namespace_for_type_drift
        if namespace
          node_type_drift_issues(namespace: namespace).each do |issue|
            issues << issue if @types.include?(issue.fetch(:type))
          end
        end
      end

      issues
    end

    def repair!
      results = { repaired: {}, now: @now }

      @graph.with_graph_lock! do
        repaired = results.fetch(:repaired)

        if @types.include?(ISSUE_MISCONFIGURED_GRAPH)
          repaired[ISSUE_MISCONFIGURED_GRAPH] = 0
        end

        if @types.include?(ISSUE_CYCLE_DETECTED)
          repaired[ISSUE_CYCLE_DETECTED] = 0
        end

        if @types.include?(ISSUE_TOPOLOGICAL_SORT_FAILED)
          repaired[ISSUE_TOPOLOGICAL_SORT_FAILED] = 0
        end

        if @types.include?(ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE)
          edge_ids = active_edge_to_inactive_node_ids
          if edge_ids.any?
            @graph.edges.where(id: edge_ids).update_all(compressed_at: @now, updated_at: @now)
          end
          repaired[ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE] = edge_ids.length
        end

        if @types.include?(ISSUE_STALE_VISIBILITY_PATCH)
          patch_ids = stale_visibility_patch_ids
          if patch_ids.any?
            DAG::NodeVisibilityPatch.where(id: patch_ids).delete_all
          end
          repaired[ISSUE_STALE_VISIBILITY_PATCH] = patch_ids.length
        end

        if @types.include?(ISSUE_STALE_RUNNING_NODE)
          node_ids = DAG::RunningLeaseReclaimer.reclaim!(graph: @graph, now: @now)
          repaired[ISSUE_STALE_RUNNING_NODE] = node_ids.length
        end

        if @types.include?(ISSUE_LEAF_INVARIANT_VIOLATION)
          created = @graph.validate_leaf_invariant!
          repaired[ISSUE_LEAF_INVARIANT_VIOLATION] = created ? 1 : 0
        end

        if @types.include?(ISSUE_UNKNOWN_NODE_TYPE)
          repaired[ISSUE_UNKNOWN_NODE_TYPE] = 0
        end

        if @types.include?(ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY)
          repaired[ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY] = 0
        end

        if @types.include?(ISSUE_NODE_BODY_DRIFT)
          repaired[ISSUE_NODE_BODY_DRIFT] = 0
        end
      end

      results
    end

    private

      def misconfigured_graph_issue
        problems = misconfigured_graph_problems
        return nil if problems.empty?

        severity = problems.any? { |problem| problem.fetch(:severity) == "error" } ? "error" : "warn"

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
            attachable_type: @graph.attachable_type,
            attachable_id: @graph.attachable_id,
            namespace: namespace,
            problems: problems,
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
            extras: { attachable_class: attachable.class.name }
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
              returned_class: namespace.class.name,
              returned_inspect: namespace.inspect,
            }
          )
          return problems
        end

        body_classes, class_problems = node_body_classes(namespace)
        problems.concat(class_problems)

        if body_classes.empty?
          problems << problem_hash(
            code: "node_body_namespace_has_no_bodies",
            severity: "error",
            message: "dag_node_body_namespace has no NodeBody classes",
            extras: { namespace: namespace.name }
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
        problems = []
        body_classes =
          namespace.constants(false).filter_map do |constant_name|
            constant = namespace.const_get(constant_name)
            next unless constant.is_a?(Class)
            next unless constant < DAG::NodeBody

            constant
          rescue StandardError => error
            problems << problem_hash(
              code: "node_body_class_load_error",
              severity: "error",
              message: "failed to load NodeBody class from namespace",
              extras: {
                namespace: namespace.name,
                constant_name: constant_name.to_s,
                error: "#{error.class}: #{error.message}",
              }
            )
            nil
          end

        [body_classes, problems]
      end

      def safe_body_class_hook(body_class, hook_name)
        [body_class.public_send(hook_name), nil]
      rescue StandardError => error
        [
          nil,
          problem_hash(
            code: "node_body_hook_error",
            severity: "error",
            message: "NodeBody hook #{hook_name} raised an error",
            extras: {
              class: body_class.name,
              hook: hook_name.to_s,
              error: "#{error.class}: #{error.message}",
            }
          ),
        ]
      end

      def node_type_key_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :node_type_key)
        problems << problem if problem
        value&.to_s
      end

      def default_leaf_repair_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :default_leaf_repair?)
        problems << problem if problem
        value == true
      end

      def executable_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :executable?)
        problems << problem if problem
        value == true
      end

      def leaf_terminal_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :leaf_terminal?)
        problems << problem if problem
        value == true
      end

      def turn_anchor_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :turn_anchor?)
        problems << problem if problem
        value == true
      end

      def transcript_candidate_for(body_class, problems:)
        value, problem = safe_body_class_hook(body_class, :transcript_candidate?)
        problems << problem if problem
        value == true
      end

      def node_type_key_mismatch_problems(body_classes)
        problems = []

        body_classes.each do |body_class|
          expected = body_class.name.demodulize.underscore
          actual = node_type_key_for(body_class, problems: problems).to_s

          next if actual == expected

          problems << problem_hash(
            code: "node_type_key_mismatch",
            severity: "error",
            message: "NodeBody node_type_key must match class name for convention mapping",
            extras: {
              class: body_class.name,
              node_type_key: actual,
              expected: expected,
            }
          )
        end

        problems
      end

      def node_type_key_collision_problems(body_classes)
        problems = []
        by_key = Hash.new { |hash, key| hash[key] = [] }

        body_classes.each do |body_class|
          key = node_type_key_for(body_class, problems: problems).to_s
          by_key[key] << body_class.name
        end

        collision_problems =
          by_key.filter_map do |key, class_names|
            next if key.present? && class_names.length == 1

            problem_hash(
              code: "node_type_key_collision",
              severity: "error",
              message: "NodeBody node_type_key must be present and unique within the namespace",
              extras: {
                key: key,
                classes: class_names.sort,
              }
            )
          end

        problems.concat(collision_problems)
        problems
      end

      def default_leaf_repair_problems(body_classes)
        problems = []
        repair_bodies =
          body_classes.select { |body_class| default_leaf_repair_for(body_class, problems: problems) }
        if repair_bodies.length != 1
          problems << problem_hash(
            code: "default_leaf_repair_not_unique",
            severity: "error",
            message: "expected exactly 1 NodeBody with default_leaf_repair?==true",
            extras: { classes: repair_bodies.map(&:name).sort }
          )
          return problems
        end

        body_class = repair_bodies.first

        unless executable_for(body_class, problems: problems)
          problems << problem_hash(
            code: "default_leaf_repair_not_executable",
            severity: "error",
            message: "default leaf repair NodeBody must be executable",
            extras: { class: body_class.name }
          )
        end

        unless leaf_terminal_for(body_class, problems: problems)
          problems << problem_hash(
            code: "default_leaf_repair_not_leaf_terminal",
            severity: "error",
            message: "default leaf repair NodeBody must be leaf_terminal",
            extras: { class: body_class.name }
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
              class: body_class.name,
              destination: destination,
            }
          )
        rescue StandardError => error
          problem_hash(
            code: "invalid_created_content_destination",
            severity: "error",
            message: "NodeBody created_content_destination raised an error",
            extras: {
              class: body_class.name,
              error: "#{error.class}: #{error.message}",
            }
          )
        end
      end

      def transcript_recent_turn_support_problems(body_classes)
        problems = []

        has_turn_anchor = false
        has_transcript_candidate = false

        body_classes.each do |body_class|
          has_turn_anchor ||= turn_anchor_for(body_class, problems: problems)
          has_transcript_candidate ||= transcript_candidate_for(body_class, problems: problems)
        end

        unless has_turn_anchor
          problems << problem_hash(
            code: "missing_turn_anchor_node_type",
            severity: "warn",
            message: "no NodeBody classes have turn_anchor?==true (transcript_recent_turns will always be empty)",
            extras: {}
          )
        end

        unless has_transcript_candidate
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
          type: type,
          severity: severity,
          subject_type: subject_type,
          subject_id: subject_id,
          details: details,
        }
      end

      def problem_hash(code:, severity:, message:, extras:)
        {
          code: code,
          severity: severity,
          message: message,
          extras: extras,
        }
      end

      def active_edge_to_inactive_node_ids
        @graph.edges.active
          .joins("JOIN dag_nodes from_nodes ON from_nodes.id = dag_edges.from_node_id")
          .joins("JOIN dag_nodes to_nodes ON to_nodes.id = dag_edges.to_node_id")
          .where("from_nodes.compressed_at IS NOT NULL OR to_nodes.compressed_at IS NOT NULL")
          .pluck(:id)
      end

      def cycle_or_toposort_failed_issue
        node_ids = @graph.nodes.active.pluck(:id)
        node_id_set = node_ids.index_by(&:itself)

        edge_pairs = @graph.edges.active.pluck(:from_node_id, :to_node_id)
        edges =
          edge_pairs.filter_map do |(from_node_id, to_node_id)|
            next unless node_id_set.key?(from_node_id) && node_id_set.key?(to_node_id)

            { from: from_node_id, to: to_node_id }
          end

        DAG::TopologicalSort.call(node_ids: node_ids, edges: edges)
        nil
      rescue DAG::TopologicalSort::CycleError
        issue_hash(
          type: ISSUE_CYCLE_DETECTED,
          severity: "error",
          subject_type: "DAG::Graph",
          subject_id: @graph.id,
          details: {
            node_count: node_ids.length,
            edge_count: edges.length,
          }
        )
      rescue StandardError => error
        issue_hash(
          type: ISSUE_TOPOLOGICAL_SORT_FAILED,
          severity: "error",
          subject_type: "DAG::Graph",
          subject_id: @graph.id,
          details: {
            node_count: node_ids.length,
            edge_count: edges.length,
            error: "#{error.class}: #{error.message}",
          }
        )
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

      def node_body_namespace_for_type_drift
        attachable = @graph.attachable
        return nil if attachable.nil?
        return nil unless attachable.respond_to?(:dag_node_body_namespace)

        namespace = attachable.dag_node_body_namespace
        return nil unless namespace.is_a?(Module)

        namespace
      rescue StandardError
        nil
      end

      def node_type_drift_issues(namespace:)
        namespace_name = namespace.name

        records =
          @graph.nodes.active
            .joins(:body)
            .pluck(
              Arel.sql("dag_nodes.id"),
              Arel.sql("dag_nodes.node_type"),
              Arel.sql("dag_node_bodies.type")
            )

        records.filter_map do |(node_id, node_type, body_type)|
          node_type = node_type.to_s
          expected_class =
            begin
              "#{namespace_name}::#{node_type.camelize}".safe_constantize
            rescue StandardError
              nil
            end

          if expected_class.nil?
            issue_hash(
              type: ISSUE_UNKNOWN_NODE_TYPE,
              severity: "error",
              subject_type: "DAG::Node",
              subject_id: node_id,
              details: {
                node_type: node_type,
                namespace: namespace_name,
              }
            )
          elsif !(expected_class < DAG::NodeBody)
            issue_hash(
              type: ISSUE_NODE_TYPE_MAPS_TO_NON_NODE_BODY,
              severity: "error",
              subject_type: "DAG::Node",
              subject_id: node_id,
              details: {
                node_type: node_type,
                namespace: namespace_name,
                mapped_class: expected_class.name,
              }
            )
          elsif body_type.to_s != expected_class.name
            issue_hash(
              type: ISSUE_NODE_BODY_DRIFT,
              severity: "error",
              subject_type: "DAG::Node",
              subject_id: node_id,
              details: {
                node_type: node_type,
                expected_body_type: expected_class.name,
                actual_body_type: body_type.to_s,
              }
            )
          end
        end
      end
  end
end
