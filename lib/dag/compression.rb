module DAG
  class Compression
    def initialize(graph:)
      @graph = graph
    end

    def compress!(node_ids:, summary_content:, summary_metadata: {})
      node_ids = Array(node_ids).map(&:to_s).uniq
      raise ArgumentError, "node_ids must not be empty" if node_ids.empty?

      @graph.with_graph_lock! do
        node_scope = @graph.nodes.where(id: node_ids).lock
        nodes = node_scope.to_a

        if nodes.length != node_ids.length
          raise ActiveRecord::RecordNotFound, "one or more nodes were not found"
        end

        if nodes.any? { |node| node.compressed_at.present? }
          raise ArgumentError, "cannot compress nodes that are already compressed"
        end

        unless nodes.all?(&:finished?)
          raise ArgumentError, "can only compress finished nodes"
        end

        edges_scope = @graph.edges.active
        blocking_edges_scope = edges_scope.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)

        incoming_edges = edges_scope.where(to_node_id: node_ids).where.not(from_node_id: node_ids).to_a
        outgoing_edges = edges_scope.where(from_node_id: node_ids).where.not(to_node_id: node_ids).to_a
        internal_edges = edges_scope.where(from_node_id: node_ids, to_node_id: node_ids).to_a

        incoming_blocking_edges =
          blocking_edges_scope.where(to_node_id: node_ids).where.not(from_node_id: node_ids).to_a
        outgoing_blocking_edges =
          blocking_edges_scope.where(from_node_id: node_ids).where.not(to_node_id: node_ids).to_a

        if outgoing_blocking_edges.empty?
          raise ArgumentError, "summary node must not become a leaf"
        end

        now = Time.current
        summary_node = @graph.nodes.create!(
          node_type: "summary",
          state: DAG::Node::FINISHED,
          body_output: { "content" => summary_content },
          metadata: summary_metadata.merge("replaces_node_ids" => node_ids),
          finished_at: now
        )

        node_scope.update_all(compressed_at: now, compressed_by_id: summary_node.id, updated_at: now)

        edges_to_compress = (incoming_edges + outgoing_edges + internal_edges).map(&:id)
        @graph.edges.where(id: edges_to_compress).update_all(compressed_at: now, updated_at: now)

        incoming_blocking_edges
          .group_by { |edge| [edge.from_node_id, edge.edge_type] }
          .each do |(from_node_id, edge_type), edges|
            @graph.edges.create!(
              from_node_id: from_node_id,
              to_node_id: summary_node.id,
              edge_type: edge_type,
              metadata: merged_rewired_edge_metadata(edges)
            )
          end

        outgoing_blocking_edges
          .group_by { |edge| [edge.to_node_id, edge.edge_type] }
          .each do |(to_node_id, edge_type), edges|
            @graph.edges.create!(
              from_node_id: summary_node.id,
              to_node_id: to_node_id,
              edge_type: edge_type,
              metadata: merged_rewired_edge_metadata(edges)
            )
          end

        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::SUBGRAPH_COMPRESSED,
          subject: summary_node,
          particulars: {
            "summary_node_id" => summary_node.id,
            "replaces_node_ids" => node_ids,
            "incoming_edge_ids" => incoming_edges.map(&:id),
            "outgoing_edge_ids" => outgoing_edges.map(&:id),
            "internal_edge_ids" => internal_edges.map(&:id),
          }
        )

        summary_node
      end
    end

    private

      def merged_rewired_edge_metadata(edges)
        replaces_edge_ids = edges.map(&:id).map(&:to_s).sort

        common = edges.first.metadata.dup
        common.delete("replaces_edge_ids")

        common.keys.each do |key|
          value = common.fetch(key)
          common.delete(key) unless edges.all? { |edge| edge.metadata[key] == value }
        end

        if edges.first.edge_type == DAG::Edge::BRANCH
          kinds =
            edges
              .flat_map { |edge| edge.metadata["branch_kinds"] || [] }
              .compact
              .uniq
              .sort

          common["branch_kinds"] = kinds if kinds.any?
        end

        common["replaces_edge_ids"] = replaces_edge_ids
        common
      end
  end
end
