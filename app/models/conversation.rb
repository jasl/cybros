class Conversation < ApplicationRecord
  include HasUuidV7Base36PrimaryKey

  has_many :dag_nodes,
    class_name: "DAG::Node",
    inverse_of: :conversation,
    dependent: :destroy
  has_many :dag_edges,
    class_name: "DAG::Edge",
    inverse_of: :conversation,
    dependent: :destroy
  has_many :events, dependent: :destroy

  def mutate!
    raise ArgumentError, "block required" unless block_given?

    executable_pending_nodes_created = false

    with_graph_lock do
      transaction do
        mutations = DAG::Mutations.new(conversation: self)
        yield mutations

        executable_pending_nodes_created =
          mutations.executable_pending_nodes_created? || validate_leaf_invariant!
      end
    end

    if executable_pending_nodes_created
      kick!
    end
  end

  def context_for(target_node_id)
    DAG::ContextAssembly.new(conversation: self).call(target_node_id)
  end

  def compress!(node_ids:, summary_content:, summary_metadata: {})
    DAG::Compression.new(conversation: self).compress!(
      node_ids: node_ids,
      summary_content: summary_content,
      summary_metadata: summary_metadata
    )
  end

  def to_mermaid(include_compressed: false, max_label_chars: 80)
    DAG::Visualization::MermaidExporter.new(
      conversation: self,
      include_compressed: include_compressed,
      max_label_chars: max_label_chars
    ).call
  end

  def kick!(limit: 10)
    DAG::TickConversationJob.perform_later(id, limit: limit)
  end

  def with_graph_lock(&block)
    with_lock(&block)
  end

  def validate_leaf_invariant!
    created_nodes = false

    leaf_nodes.each do |leaf|
      next if leaf.node_type == DAG::Node::AGENT_MESSAGE
      next if leaf.pending? || leaf.running?

      agent_message = dag_nodes.create!(
        node_type: DAG::Node::AGENT_MESSAGE,
        state: DAG::Node::PENDING,
        metadata: { "generated_by" => "leaf_invariant" }
      )
      dag_edges.create!(
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
    nodes_scope = dag_nodes
    edges_scope = dag_edges

    unless include_compressed
      nodes_scope = nodes_scope.where(compressed_at: nil)
      edges_scope = edges_scope.where(compressed_at: nil)
    end

    nodes_scope.where.not(id: edges_scope.select(:from_node_id))
  end

  def record_event!(event_type:, subject: nil, particulars: {})
    events.create!(event_type: event_type, subject: subject, particulars: particulars)
  end
end
