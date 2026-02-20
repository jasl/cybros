module DAG
  class ContextClosureAssembly
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
        target_node_id = target_node_id.to_s
        return [] unless @graph.nodes.active.where(id: target_node_id).exists?

        active_node_ids = @graph.nodes.active.select(:id)
        edge_rows =
          @graph.edges.active
            .where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
            .where(from_node_id: active_node_ids, to_node_id: active_node_ids)
            .pluck(:from_node_id, :to_node_id)

        incoming = Hash.new { |hash, key| hash[key] = [] }
        edge_rows.each do |from_node_id, to_node_id|
          incoming[to_node_id.to_s] << from_node_id.to_s
        end

        visited = { target_node_id => true }
        stack = [target_node_id]

        while (node_id = stack.pop)
          incoming[node_id].each do |parent_id|
            next if visited[parent_id]

            visited[parent_id] = true
            stack << parent_id
          end
        end

        visited.keys
      end

      def load_nodes(node_ids)
        @graph.nodes
          .where(id: node_ids, compressed_at: nil)
          .select(:id, :turn_id, :subgraph_id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
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
          "turn_id" => node.turn_id,
          "subgraph_id" => node.subgraph_id,
          "node_type" => node.node_type,
          "state" => node.state,
          "payload" => payload_hash,
          "metadata" => node.metadata,
        }
      end
  end
end
