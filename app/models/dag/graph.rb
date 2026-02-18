module DAG
  class Graph < ApplicationRecord
    self.table_name = "dag_graphs"

    LOCK_PREFIX = "dag:advisory:graph".freeze

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :graph
    has_many :edges,
             class_name: "DAG::Edge",
             inverse_of: :graph

    before_destroy :purge_graph_records

    def mutate!
      raise ArgumentError, "block required" unless block_given?

      executable_pending_nodes_created = false

      with_graph_lock! do
        mutations = DAG::Mutations.new(graph: self)
        yield mutations

        executable_pending_nodes_created =
          mutations.executable_pending_nodes_created? || validate_leaf_invariant!
      end

      if executable_pending_nodes_created
        kick!
      end
    end

    def context_for(target_node_id, mode: :preview)
      DAG::ContextAssembly.new(graph: self).call(target_node_id, mode: mode)
    end

    def context_for_full(target_node_id)
      context_for(target_node_id, mode: :full)
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

    def policy
      key = attachable_cache_key
      if defined?(@policy_cache_key) && @policy_cache_key == key
        return @policy
      end

      @policy_cache_key = key

      @policy =
        if attachable&.respond_to?(:dag_graph_policy)
          attachable.dag_graph_policy || DAG::GraphPolicies::Default.new
        else
          DAG::GraphPolicies::Default.new
        end
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
        next if policy.leaf_valid?(leaf)

        repaired_node = nodes.create!(policy.leaf_repair_node_attributes(leaf))
        edges.create!(
          policy.leaf_repair_edge_attributes(leaf, repaired_node).merge(
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
        end
      end
  end
end
