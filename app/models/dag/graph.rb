module DAG
  class Graph < ApplicationRecord
    self.table_name = "dag_graphs"

    LOCK_PREFIX = "dag:advisory:graph".freeze

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :lanes,
             class_name: "DAG::Lane",
             inverse_of: :graph
    has_many :turns,
             class_name: "DAG::Turn",
             inverse_of: :graph
    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :graph
    has_many :node_events,
             class_name: "DAG::NodeEvent",
             inverse_of: :graph
    has_many :edges,
             class_name: "DAG::Edge",
             inverse_of: :graph

    after_create :ensure_main_lane
    before_destroy :purge_graph_records

    def mutate!(turn_id: nil)
      raise ArgumentError, "block required" unless block_given?

      executable_pending_nodes_created = false

      with_graph_lock! do
        mutations = DAG::Mutations.new(graph: self, turn_id: turn_id)
        yield mutations

        executable_pending_nodes_created =
          mutations.executable_pending_nodes_created? || validate_leaf_invariant!
      end

      if executable_pending_nodes_created
        kick!
      end
    end

    def main_lane
      lane = lanes.find_by(role: DAG::Lane::MAIN)
      return lane if lane

      begin
        lanes.create!(role: DAG::Lane::MAIN, metadata: {})
      rescue ActiveRecord::RecordNotUnique
        lanes.find_by!(role: DAG::Lane::MAIN)
      end
    end

    def context_for(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      mode: :preview,
      include_excluded: false,
      include_deleted: false
    )
      DAG::ContextWindowAssembly.new(graph: self).call(
        target_node_id,
        limit_turns: limit_turns,
        mode: mode,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_for_full(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      include_excluded: false,
      include_deleted: false
    )
      context_for(
        target_node_id,
        limit_turns: limit_turns,
        mode: :full,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_closure_for(target_node_id, mode: :preview, include_excluded: false, include_deleted: false)
      DAG::ContextClosureAssembly.new(graph: self).call(
        target_node_id,
        mode: mode,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_closure_for_full(target_node_id, include_excluded: false, include_deleted: false)
      context_closure_for(
        target_node_id,
        mode: :full,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_node_scope_for(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      include_excluded: false,
      include_deleted: false
    )
      DAG::ContextWindowAssembly.new(graph: self).node_scope_for(
        target_node_id,
        limit_turns: limit_turns,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def node_event_page_for(node_id, after_event_id: nil, limit: 200, kinds: nil)
      limit = Integer(limit)
      raise ArgumentError, "limit must be > 0" if limit <= 0

      limit = [limit, 1000].min

      scope = node_event_scope_for(node_id, kinds: kinds).ordered

      if after_event_id.present?
        scope = scope.where("id > ?", after_event_id)
      end

      scope
        .limit(limit)
        .select(:id, :node_id, :kind, :text, :payload, :created_at)
        .map do |event|
          {
            "event_id" => event.id,
            "node_id" => event.node_id,
            "kind" => event.kind,
            "text" => event.text,
            "payload" => event.payload,
            "created_at" => event.created_at&.iso8601,
          }
        end
    end

    def node_event_scope_for(node_id, kinds: nil)
      scope = node_events.where(node_id: node_id)

      kinds = Array(kinds).map(&:to_s).reject(&:blank?) if kinds
      if kinds&.any?
        scope = scope.where(kind: kinds)
      end

      scope
    end

    def transcript_for(target_node_id, limit: nil, mode: :preview, include_deleted: false)
      unless include_deleted
        deleted_at = nodes.where(id: target_node_id).pick(:deleted_at)
        return [] if deleted_at.present?
      end

      transcript = context_closure_for(
        target_node_id,
        mode: mode,
        include_excluded: true,
        include_deleted: include_deleted
      )

      projection = DAG::TranscriptProjection.new(graph: self)
      transcript = projection.apply_rules(context_nodes: transcript)

      if limit
        transcript = transcript.last(Integer(limit))
      end

      transcript
    end

    def transcript_for_full(target_node_id, limit: nil, include_deleted: false)
      transcript_for(
        target_node_id,
        limit: limit,
        mode: :full,
        include_deleted: include_deleted
      )
    end

    def transcript_recent_turns(limit_turns:, mode: :preview, include_deleted: false)
      limit_turns = Integer(limit_turns)
      return [] if limit_turns <= 0

      turn_scope =
        turns
          .where.not(anchor_node_id: nil)
          .joins(<<~SQL.squish)
            JOIN dag_nodes anchors
              ON anchors.id = dag_turns.anchor_node_id
             AND anchors.graph_id = dag_turns.graph_id
             AND anchors.lane_id = dag_turns.lane_id
          SQL
          .where(Arel.sql("anchors.compressed_at IS NULL"))

      turn_scope = turn_scope.where(Arel.sql("anchors.deleted_at IS NULL")) unless include_deleted

      turn_ids =
        turn_scope
          .order(Arel.sql("dag_turns.anchor_created_at DESC"), Arel.sql("dag_turns.anchor_node_id DESC"))
          .limit(limit_turns)
          .pluck(Arel.sql("dag_turns.id"))
          .reverse

      return [] if turn_ids.empty?

      candidate_types = transcript_candidate_node_types
      return [] if candidate_types.empty?

      node_scope =
        nodes.active.where(
          turn_id: turn_ids,
          node_type: candidate_types
        )
      node_scope = node_scope.where(deleted_at: nil) unless include_deleted

      node_records =
        node_scope
          .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id)
          .order(:id)
          .to_a

      by_turn = node_records.group_by(&:turn_id)
      ordered_nodes = turn_ids.flat_map { |turn_id| by_turn.fetch(turn_id, []) }

      projection = DAG::TranscriptProjection.new(graph: self)
      projection.project(node_records: ordered_nodes, mode: mode)
    end

    def transcript_recent_turns_full(limit_turns:, include_deleted: false)
      transcript_recent_turns(limit_turns: limit_turns, mode: :full, include_deleted: include_deleted)
    end

    def transcript_page(lane_id:, limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview, include_deleted: false)
      lane = lanes.find(lane_id)
      lane.transcript_page(
        limit_turns: limit_turns,
        before_turn_id: before_turn_id,
        after_turn_id: after_turn_id,
        mode: mode,
        include_deleted: include_deleted
      )
    end

    def turn_anchor_node_types
      node_type_keys_for_hook(:turn_anchor?)
    end

    def transcript_candidate_node_types
      node_type_keys_for_hook(:transcript_candidate?)
    end

    def compress!(node_ids:, summary_content:, summary_metadata: {})
      DAG::Compression.new(graph: self).compress!(
        node_ids: node_ids,
        summary_content: summary_content,
        summary_metadata: summary_metadata
      )
    end

    def to_mermaid(include_compressed: false, max_label_chars: 80)
      DAG::Visualization::MermaidExporter.new(
        graph: self,
        include_compressed: include_compressed,
        max_label_chars: max_label_chars
      ).call
    end

    def kick!(limit: 10)
      DAG::TickGraphJob.perform_later(id, limit: limit)
    end

    def apply_visibility_patches_if_idle!
      applied = 0
      now = Time.current

      DAG::NodeVisibilityPatch.where(graph_id: id).order(:updated_at, :id).lock.find_each do |patch|
        node = nodes.find_by(id: patch.node_id)

        if node.nil? || node.compressed_at.present? || node.graph_id != id
          emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_PATCH_DROPPED,
            subject_type: "DAG::Node",
            subject_id: patch.node_id,
            particulars: {
              "patch_id" => patch.id,
              "reason" => node.nil? ? "node_missing" : "node_inactive_or_mismatched_graph",
            }
          )
          patch.destroy!
          next
        end

        next unless visibility_mutation_allowed?(node: node, graph: self)

        from = {
          "context_excluded_at" => node.context_excluded_at&.iso8601,
          "deleted_at" => node.deleted_at&.iso8601,
        }
        to = {
          "context_excluded_at" => patch.context_excluded_at&.iso8601,
          "deleted_at" => patch.deleted_at&.iso8601,
        }

        if from != to
          node.update_columns(
            context_excluded_at: patch.context_excluded_at,
            deleted_at: patch.deleted_at,
            updated_at: now
          )

          emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGED,
            subject: node,
            particulars: {
              "action" => "apply_visibility_patch",
              "source" => "defer_apply",
              "from" => from,
              "to" => to,
            }
          )
        end

        patch.destroy!
        applied += 1
      end

      applied
    end

    def active_nodes_for_turn(turn_id)
      nodes.active.where(turn_id: turn_id)
    end

    def turn_node_ids(turn_id, include_compressed: false)
      scope = include_compressed ? nodes : nodes.active
      scope.where(turn_id: turn_id).pluck(:id)
    end

    def turn_stable?(turn_id)
      active_nodes_for_turn(turn_id).where.not(state: DAG::Node::TERMINAL_STATES).none?
    end

    def hooks
      key = attachable_cache_key
      if defined?(@hooks_cache_key) && @hooks_cache_key == key
        return @hooks
      end

      @hooks_cache_key = key

      @hooks =
        if attachable&.respond_to?(:dag_graph_hooks)
          attachable.dag_graph_hooks || DAG::GraphHooks::NOOP
        else
          DAG::GraphHooks::NOOP
        end
    end

    def body_class_for_node_type(node_type)
      node_type = node_type.to_s

      if attachable&.respond_to?(:dag_node_body_namespace)
        namespace = attachable.dag_node_body_namespace
        raise KeyError, "dag_node_body_namespace must be a Module" unless namespace.is_a?(Module)

        class_name = "#{namespace.name}::#{node_type.camelize}"
        body_class = class_name.safe_constantize
        raise KeyError, "unknown node_type=#{node_type}" if body_class.nil?
        raise KeyError, "node_type=#{node_type} maps to non-NodeBody #{body_class.name}" unless body_class < DAG::NodeBody

        body_class
      else
        raise KeyError, "attachable must define dag_node_body_namespace"
      end
    end

    def leaf_valid?(node)
      return true unless attachable&.respond_to?(:dag_node_body_namespace)

      if leaf_terminal_node_types.include?(node.node_type.to_s)
        true
      else
        node.pending? || node.running?
      end
    end

    def leaf_repair_node_attributes(leaf)
      node_type = default_leaf_repair_node_type
      lane_archived = leaf.lane&.archived?

      metadata = { "generated_by" => "leaf_invariant" }

      if lane_archived
        now = Time.current
        metadata["reason"] = "lane_archived"
        metadata["transcript_preview"] = "Archived"

        {
          node_type: node_type,
          state: DAG::Node::FINISHED,
          lane_id: leaf.lane_id,
          finished_at: now,
          metadata: metadata,
        }
      else
        {
          node_type: node_type,
          state: DAG::Node::PENDING,
          lane_id: leaf.lane_id,
          metadata: metadata,
        }
      end
    end

    def leaf_repair_edge_attributes(_leaf, _repaired_node)
      {
        edge_type: DAG::Edge::SEQUENCE,
        metadata: { "generated_by" => "leaf_invariant" },
      }
    end

    def transcript_include?(context_node_hash)
      body_class = body_class_for_context_node_hash(context_node_hash)
      return false if body_class.nil?

      body_class.transcript_include?(context_node_hash)
    end

    def transcript_preview_override(context_node_hash)
      body_class = body_class_for_context_node_hash(context_node_hash)
      return nil if body_class.nil?

      body_class.transcript_preview_override(context_node_hash)
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

    def emit_event(event_type:, particulars: {}, subject: nil, subject_type: nil, subject_id: nil)
      event_type = event_type.to_s
      validate_event_type!(event_type)

      if subject
        subject_type = subject.class.name
        subject_id = subject.id
      end

      raise ArgumentError, "subject_type required" if subject_type.blank?
      raise ArgumentError, "subject_id required" if subject_id.blank?

      begin
        hooks.record_event(
          graph: self,
          event_type: event_type,
          subject_type: subject_type,
          subject_id: subject_id,
          particulars: particulars
        )
      rescue StandardError => error
        Rails.logger.error(
          "[DAG] graph_hooks_error graph_id=#{id} event_type=#{event_type} " \
          "subject_type=#{subject_type} subject_id=#{subject_id} error=#{error.class}: #{error.message}"
        )
        nil
      end
    end

    def advisory_lock_name
      raise "graph must be persisted" if id.blank?

      "#{LOCK_PREFIX}:#{id}"
    end

    def with_graph_lock!(&block)
      raise ArgumentError, "block required" unless block_given?

      self.class.with_advisory_lock!(advisory_lock_name) do
        transaction do
          lock!
          yield
        end
      end
    end

    def with_graph_try_lock(&block)
      raise ArgumentError, "block required" unless block_given?

      self.class.with_advisory_lock(advisory_lock_name, timeout_seconds: 0) do
        transaction do
          lock!
          return yield
        end
      end

      false
    end

    def validate_leaf_invariant!
      created_nodes = false

      leaf_nodes.each do |leaf|
        next if leaf_valid?(leaf)

        repaired_node = nodes.create!(leaf_repair_node_attributes(leaf).merge(turn_id: leaf.turn_id))
        edges.create!(
          leaf_repair_edge_attributes(leaf, repaired_node).merge(
            from_node_id: leaf.id,
            to_node_id: repaired_node.id
          )
        )

        emit_event(
          event_type: DAG::GraphHooks::EventTypes::LEAF_INVARIANT_REPAIRED,
          subject: repaired_node,
          particulars: { "leaf_node_id" => leaf.id }
        )

        created_nodes = true
      end

      created_nodes
    end

    def leaf_nodes(include_compressed: false)
      nodes_scope = nodes
      edges_scope = edges.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)

      unless include_compressed
        nodes_scope = nodes_scope.where(compressed_at: nil)
        edges_scope = edges_scope.where(compressed_at: nil)
        edges_scope = edges_scope.where(to_node_id: nodes_scope.select(:id))
      end

      nodes_scope.where.not(id: edges_scope.select(:from_node_id))
    end

    private

      def body_class_for_context_node_hash(context_node_hash)
        node_type = context_node_hash["node_type"].to_s

        body_class_for_node_type(node_type)
      rescue KeyError, ArgumentError
        nil
      end

      def node_body_namespace
        return nil unless attachable&.respond_to?(:dag_node_body_namespace)

        namespace = attachable.dag_node_body_namespace
        return nil unless namespace.is_a?(Module)

        namespace
      end

      def node_body_classes
        namespace = node_body_namespace
        return [] if namespace.nil?

        key = attachable_cache_key
        if defined?(@node_body_classes_cache_key) && @node_body_classes_cache_key == key
          return @node_body_classes
        end

        @node_body_classes_cache_key = key

        @node_body_classes =
          namespace.constants(false).filter_map do |constant_name|
            constant = namespace.const_get(constant_name)
            next unless constant.is_a?(Class)
            next unless constant < DAG::NodeBody

            constant
          rescue NameError
            nil
          end
      end

      def node_type_keys_for_hook(hook_name)
        node_body_classes
          .select { |body_class| body_class.public_send(hook_name) }
          .filter_map(&:node_type_key)
          .compact
          .uniq
      end

      def leaf_terminal_node_types
        node_type_keys_for_hook(:leaf_terminal?)
      end

      def default_leaf_repair_node_type
        bodies = node_body_classes.select(&:default_leaf_repair?)
        if bodies.length != 1
          raise "expected exactly 1 NodeBody with default_leaf_repair?==true, got #{bodies.map(&:name).inspect}"
        end

        node_type_key = bodies.first.node_type_key.to_s
        raise "default leaf repair NodeBody has blank node_type_key" if node_type_key.blank?

        node_type_key
      end

      def attachable_cache_key
        [attachable_type, attachable_id]
      end

      def validate_event_type!(event_type)
        return if DAG::GraphHooks::EventTypes::ALL.include?(event_type)

        raise ArgumentError,
              "unknown DAG graph hook event_type=#{event_type.inspect}. " \
              "Add it to DAG::GraphHooks::EventTypes and update docs/spec."
      end

      def purge_graph_records
        self.class.with_connection do |connection|
          graph_id_quoted = connection.quote(id)

          connection.delete(<<~SQL.squish, "purge_dag_visibility_patches")
            DELETE FROM dag_node_visibility_patches WHERE graph_id = #{graph_id_quoted}
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_edges")
            DELETE FROM dag_edges WHERE graph_id = #{graph_id_quoted}
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_nodes_and_bodies")
            WITH deleted_nodes AS (
              DELETE FROM dag_nodes WHERE graph_id = #{graph_id_quoted}
              RETURNING body_id
            )
            DELETE FROM dag_node_bodies
            USING deleted_nodes
            WHERE dag_node_bodies.id = deleted_nodes.body_id
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_lanes")
            DELETE FROM dag_lanes WHERE graph_id = #{graph_id_quoted}
          SQL
        end
      end

      def ensure_main_lane
        main_lane
      end
  end
end
