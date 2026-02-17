module DAG
  class ContextAssembly
    def initialize(graph:)
      @graph = graph
    end

    def call(target_node_id, mode: :preview)
      node_ids = ancestor_node_ids_for(target_node_id)
      nodes = load_nodes(node_ids)
      payloads = load_payloads(nodes: nodes, mode: mode)

      edges = @graph.edges.active.where(
        edge_type: DAG::Edge::BLOCKING_EDGE_TYPES,
        from_node_id: nodes.keys,
        to_node_id: nodes.keys
      ).pluck(:from_node_id, :to_node_id).map do |from_node_id, to_node_id|
        { from: from_node_id, to: to_node_id }
      end

      ordered_ids = DAG::TopologicalSort.call(node_ids: nodes.keys, edges: edges)
      ordered_ids.map do |node_id|
        node = nodes.fetch(node_id)
        payload = payloads[node.payload_id]
        context_hash_for(node, payload, mode: mode)
      end
    end

    private

      def ancestor_node_ids_for(target_node_id)
        DAG::Node.with_connection do |connection|
          target_quoted = connection.quote(target_node_id)
          graph_quoted = connection.quote(@graph.id)

          sql = <<~SQL
            WITH RECURSIVE ancestors(node_id) AS (
              SELECT #{target_quoted}::uuid
              UNION
              SELECT e.from_node_id
              FROM dag_edges e
              JOIN ancestors a ON e.to_node_id = a.node_id
              WHERE e.graph_id = #{graph_quoted}
                AND e.compressed_at IS NULL
                AND e.edge_type IN ('sequence', 'dependency')
            )
            SELECT DISTINCT node_id FROM ancestors
          SQL

          connection.select_values(sql)
        end
      end

      def load_nodes(node_ids)
        @graph.nodes
          .where(id: node_ids, compressed_at: nil)
          .select(:id, :node_type, :state, :metadata, :payload_id)
          .index_by(&:id)
      end

      def load_payloads(nodes:, mode:)
        payload_ids = nodes.values.map(&:payload_id).compact.uniq

        payload_scope = DAG::NodePayload.where(id: payload_ids)
        payload_scope =
          if mode.to_sym == :full
            payload_scope.select(:id, :type, :input, :output, :output_preview)
          else
            payload_scope.select(:id, :type, :input, :output_preview)
          end

        payload_scope.index_by(&:id)
      end

      def context_hash_for(node, payload, mode:)
        payload_hash = {
          "input" => payload&.input.is_a?(Hash) ? payload.input : {},
          "output_preview" => payload&.output_preview.is_a?(Hash) ? payload.output_preview : {},
        }

        if mode.to_sym == :full
          payload_hash["output"] = payload&.output.is_a?(Hash) ? payload.output : {}
        end

        {
          "node_id" => node.id,
          "node_type" => node.node_type,
          "state" => node.state,
          "payload" => payload_hash,
          "metadata" => node.metadata,
        }
      end
  end
end
