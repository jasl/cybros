module DAG
  class ContextAssembly
    def initialize(graph:)
      @graph = graph
    end

    def call(target_node_id, mode: :preview, include_excluded: false, include_deleted: false)
      node_ids = ancestor_node_ids_for(target_node_id)
      nodes = load_nodes(node_ids)

      edges = @graph.edges.active.where(
        edge_type: DAG::Edge::BLOCKING_EDGE_TYPES,
        from_node_id: nodes.keys,
        to_node_id: nodes.keys
      ).pluck(:from_node_id, :to_node_id).map do |from_node_id, to_node_id|
        { from: from_node_id, to: to_node_id }
      end

      ordered_ids = DAG::TopologicalSort.call(node_ids: nodes.keys, edges: edges)

      included_ids = ordered_ids.select do |node_id|
        include_node_in_context?(
          nodes.fetch(node_id),
          target_node_id: target_node_id,
          include_excluded: include_excluded,
          include_deleted: include_deleted
        )
      end

      included_nodes = included_ids.map { |node_id| nodes.fetch(node_id) }
      bodies = load_bodies(nodes: included_nodes, mode: mode)

      included_ids.map do |node_id|
        node = nodes.fetch(node_id)
        body = bodies[node.body_id]
        context_hash_for(node, body, mode: mode)
      end
    end

    private

      def ancestor_node_ids_for(target_node_id)
        DAG::Node.with_connection do |connection|
          target_quoted = connection.quote(target_node_id)
          graph_quoted = connection.quote(@graph.id)

          sql = <<~SQL
            WITH RECURSIVE ancestors(node_id) AS (
              SELECT dag_nodes.id
              FROM dag_nodes
              WHERE dag_nodes.id = #{target_quoted}::uuid
                AND dag_nodes.graph_id = #{graph_quoted}
                AND dag_nodes.compressed_at IS NULL
              UNION
              SELECT e.from_node_id
              FROM dag_edges e
              JOIN ancestors a ON e.to_node_id = a.node_id
              JOIN dag_nodes parent
                ON parent.id = e.from_node_id
               AND parent.graph_id = e.graph_id
               AND parent.compressed_at IS NULL
              JOIN dag_nodes child
                ON child.id = e.to_node_id
               AND child.graph_id = e.graph_id
               AND child.compressed_at IS NULL
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
          .select(:id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
          .index_by(&:id)
      end

      def load_bodies(nodes:, mode:)
        body_ids = nodes.map(&:body_id).compact.uniq

        body_scope = DAG::NodeBody.where(id: body_ids)
        body_scope =
          if mode.to_sym == :full
            body_scope.select(:id, :type, :input, :output, :output_preview)
          else
            body_scope.select(:id, :type, :input, :output_preview)
          end

        body_scope.index_by(&:id)
      end

      def include_node_in_context?(node, target_node_id:, include_excluded:, include_deleted:)
        return true if node.id.to_s == target_node_id.to_s

        return false if !include_deleted && node.deleted_at.present?
        return false if !include_excluded && node.context_excluded_at.present?

        true
      end

      def context_hash_for(node, body, mode:)
        payload_hash = {
          "input" => body&.input.is_a?(Hash) ? body.input : {},
          "output_preview" => body&.output_preview.is_a?(Hash) ? body.output_preview : {},
        }

        if mode.to_sym == :full
          payload_hash["output"] = body&.output.is_a?(Hash) ? body.output : {}
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
