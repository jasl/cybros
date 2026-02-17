module DAG
  class Mutations
    def initialize(conversation:)
      @conversation = conversation
      @executable_pending_nodes_created = false
    end

    def create_node(node_type:, state:, content: nil, metadata: {})
      node = @conversation.dag_nodes.create!(
        node_type: node_type,
        state: state,
        content: content,
        metadata: metadata
      )

      @conversation.record_event!(
        event_type: "node_created",
        subject: node,
        particulars: { "node_type" => node.node_type, "state" => node.state }
      )

      if node.executable? && node.pending?
        @executable_pending_nodes_created = true
      end

      node
    end

    def create_edge(from_node:, to_node:, edge_type:, metadata: {})
      edge = @conversation.dag_edges.create!(
        from_node_id: from_node.id,
        to_node_id: to_node.id,
        edge_type: edge_type,
        metadata: metadata
      )

      @conversation.record_event!(
        event_type: "edge_created",
        subject: edge,
        particulars: {
          "edge_type" => edge.edge_type,
          "from_node_id" => edge.from_node_id,
          "to_node_id" => edge.to_node_id,
        }
      )

      edge
    end

    def executable_pending_nodes_created?
      @executable_pending_nodes_created
    end
  end
end
