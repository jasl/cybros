module DAG
  class Compression
    def initialize(conversation:)
      @conversation = conversation
    end

    def compress!(node_ids:, summary_content:, summary_metadata: {})
      node_ids = Array(node_ids).map(&:to_s).uniq
      raise ArgumentError, "node_ids must not be empty" if node_ids.empty?

      @conversation.with_graph_lock do
        @conversation.transaction do
          node_scope = @conversation.dag_nodes.where(id: node_ids).lock
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

          edges_scope = @conversation.dag_edges.active
          incoming_edges = edges_scope.where(to_node_id: node_ids).where.not(from_node_id: node_ids).to_a
          outgoing_edges = edges_scope.where(from_node_id: node_ids).where.not(to_node_id: node_ids).to_a
          internal_edges = edges_scope.where(from_node_id: node_ids, to_node_id: node_ids).to_a

          if outgoing_edges.empty?
            raise ArgumentError, "summary node must not become a leaf"
          end

          now = Time.current
          summary_node = @conversation.dag_nodes.create!(
            node_type: DAG::Node::SUMMARY,
            state: DAG::Node::FINISHED,
            content: summary_content,
            metadata: summary_metadata.merge("replaces_node_ids" => node_ids),
            finished_at: now
          )

          node_scope.update_all(compressed_at: now, compressed_by_id: summary_node.id, updated_at: now)

          edges_to_compress = (incoming_edges + outgoing_edges + internal_edges).map(&:id)
          DAG::Edge.where(id: edges_to_compress).update_all(compressed_at: now, updated_at: now)

          incoming_edges.each do |edge|
            @conversation.dag_edges.create!(
              from_node_id: edge.from_node_id,
              to_node_id: summary_node.id,
              edge_type: edge.edge_type,
              metadata: edge.metadata.merge("replaces_edge_id" => edge.id)
            )
          end

          outgoing_edges.each do |edge|
            @conversation.dag_edges.create!(
              from_node_id: summary_node.id,
              to_node_id: edge.to_node_id,
              edge_type: edge.edge_type,
              metadata: edge.metadata.merge("replaces_edge_id" => edge.id)
            )
          end

          @conversation.record_event!(
            event_type: "subgraph_compressed",
            subject: summary_node,
            particulars: {
              "summary_node_id" => summary_node.id,
              "replaces_node_ids" => node_ids,
              "incoming_edge_ids" => incoming_edges.map(&:id),
              "outgoing_edge_ids" => outgoing_edges.map(&:id),
              "internal_edge_ids" => internal_edges.map(&:id)
            }
          )

          summary_node
        end
      end
    end
  end
end
