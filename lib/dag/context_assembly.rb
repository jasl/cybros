module DAG
  class ContextAssembly
    def initialize(conversation:)
      @conversation = conversation
    end

    def call(target_node_id)
      node_ids = ancestor_node_ids_for(target_node_id)
      nodes = @conversation.dag_nodes.where(id: node_ids, compressed_at: nil).index_by(&:id)

      edges = @conversation.dag_edges.active.where(
        edge_type: DAG::Edge::BLOCKING_EDGE_TYPES,
        from_node_id: nodes.keys,
        to_node_id: nodes.keys
      ).pluck(:from_node_id, :to_node_id).map do |from_node_id, to_node_id|
        { from: from_node_id, to: to_node_id }
      end

      ordered_ids = DAG::TopologicalSort.call(node_ids: nodes.keys, edges: edges)
      ordered_ids.map { |node_id| nodes.fetch(node_id).as_context_hash }
    end

    private
      def ancestor_node_ids_for(target_node_id)
        DAG::Node.with_connection do |connection|
          target_quoted = connection.quote(target_node_id)
          conversation_quoted = connection.quote(@conversation.id)

          sql = <<~SQL
            WITH RECURSIVE ancestors(node_id) AS (
              SELECT #{target_quoted}::text
              UNION
              SELECT e.from_node_id
              FROM dag_edges e
              JOIN ancestors a ON e.to_node_id = a.node_id
              WHERE e.conversation_id = #{conversation_quoted}
                AND e.compressed_at IS NULL
                AND (
                  e.edge_type IN ('sequence', 'dependency')
                  OR (
                    e.edge_type = 'branch'
                    AND (e.metadata->>'branch_kind') = 'fork'
                  )
                )
            )
            SELECT DISTINCT node_id FROM ancestors
          SQL

          connection.select_values(sql)
        end
      end
  end
end
