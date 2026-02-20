class Conversation < ApplicationRecord
  has_one :dag_graph, class_name: "DAG::Graph", as: :attachable,
          dependent: :destroy, autosave: true
  delegate :mutate!, :compress!, :kick!, :context_for, :context_for_full,
           :context_closure_for, :context_closure_for_full,
           :awaiting_approval_page, :awaiting_approval_scope,
           :node_event_page_for, :node_event_scope_for,
           :context_node_scope_for, :to_mermaid,
           to: :dag_graph, allow_nil: false
  delegate :transcript_for, :transcript_for_full,
           to: :dag_graph, allow_nil: false
  delegate :transcript_recent_turns, :transcript_recent_turns_full,
           to: :dag_graph, allow_nil: false

  has_many :events, dependent: :destroy
  has_many :topics, dependent: :destroy

  after_initialize do
    build_dag_graph if new_record? && dag_graph.nil?
  end

  def dag_node_body_namespace
    Messages
  end

  def dag_graph_hooks
    @dag_graph_hooks ||= Messages::GraphHooks.new(conversation: self)
  end

  def ensure_main_topic
    topic = topics.find_by(role: Topic::MAIN)
    if topic.nil?
      begin
        topic = topics.create!(role: Topic::MAIN, title: title, metadata: {})
      rescue ActiveRecord::RecordNotUnique
        topic = topics.find_by!(role: Topic::MAIN)
      end
    end

    subgraph = dag_graph.main_subgraph
    if subgraph.attachable.nil?
      subgraph.update!(attachable: topic)
    elsif subgraph.attachable != topic
      raise ArgumentError, "main subgraph is already attached to a different model"
    end

    topic
  end

  def fork_topic_from(from_node:, title:, user_content:)
    topic = topics.create!(role: Topic::BRANCH, title: title, metadata: {})

    root_node = nil
    dag_graph.mutate! do |m|
      root_node = m.fork_from!(
        from_node: from_node,
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        content: user_content,
        metadata: {}
      )
    end

    root_node.subgraph.update!(attachable: topic)
    topic
  end

  def merge_topic_into_main(source_topic:, main_topic: ensure_main_topic, metadata: {})
    source_subgraph = source_topic.dag_subgraph
    raise ArgumentError, "source_topic is missing dag_subgraph" if source_subgraph.nil?

    main_subgraph = main_topic.dag_subgraph
    raise ArgumentError, "main_topic is missing dag_subgraph" if main_subgraph.nil?

    main_head = dag_graph.leaf_nodes.where(subgraph_id: main_subgraph.id).sole
    source_head = dag_graph.leaf_nodes.where(subgraph_id: source_subgraph.id).sole

    merge_node = nil
    dag_graph.mutate! do |m|
      merge_node = m.merge_subgraphs!(
        target_subgraph: main_subgraph,
        target_from_node: main_head,
        source_subgraphs_and_nodes: [{ subgraph: source_subgraph, from_node: source_head }],
        node_type: Messages::AgentMessage.node_type_key,
        metadata: metadata
      )
    end

    merge_node
  end
end
