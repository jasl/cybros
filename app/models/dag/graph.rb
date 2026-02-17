module DAG
  class Graph < ApplicationRecord
    self.table_name = "dag_graphs"

    LOCK_PREFIX = "dag:advisory:graph".freeze

    belongs_to :attachable, polymorphic: true

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

    def record_event!(event_type:, subject:, particulars: {})
      attachable.record_event!(event_type: event_type, subject: subject, particulars: particulars)
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
        next if leaf.node_type == DAG::Node::AGENT_MESSAGE
        next if leaf.pending? || leaf.running?

        agent_message = nodes.create!(
          node_type: DAG::Node::AGENT_MESSAGE,
          state: DAG::Node::PENDING,
          metadata: { "generated_by" => "leaf_invariant" }
        )
        edges.create!(
          from_node_id: leaf.id,
          to_node_id: agent_message.id,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: { "generated_by" => "leaf_invariant" }
        )

        record_event!(
          event_type: "leaf_invariant_repaired",
          subject: agent_message,
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

      def purge_graph_records
        self.class.with_connection do |connection|
          graph_id_quoted = connection.quote(id)

          connection.delete(<<~SQL.squish, "purge_dag_edges")
            DELETE FROM dag_edges WHERE graph_id = #{graph_id_quoted}
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_nodes_and_payloads")
            WITH deleted_nodes AS (
              DELETE FROM dag_nodes WHERE graph_id = #{graph_id_quoted}
              RETURNING payload_id
            )
            DELETE FROM dag_node_payloads
            USING deleted_nodes
            WHERE dag_node_payloads.id = deleted_nodes.payload_id
          SQL
        end
      end
  end
end
