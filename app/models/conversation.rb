class Conversation < ApplicationRecord
  has_one :dag_graph, class_name: "DAG::Graph", as: :attachable,
          dependent: :destroy, autosave: true
  delegate :mutate!, :compress!, :kick!, :context_for, :context_for_full,
           :context_closure_for, :context_closure_for_full,
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

    lane = dag_graph.main_lane
    if lane.attachable.nil?
      lane.update!(attachable: topic)
    elsif lane.attachable != topic
      raise ArgumentError, "main lane is already attached to a different model"
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

    root_node.lane.update!(attachable: topic)
    topic
  end

  def merge_topic_into_main(source_topic:, main_topic: ensure_main_topic, metadata: {})
    source_lane = source_topic.dag_lane
    raise ArgumentError, "source_topic is missing dag_lane" if source_lane.nil?

    main_lane = main_topic.dag_lane
    raise ArgumentError, "main_topic is missing dag_lane" if main_lane.nil?

    main_head = dag_graph.leaf_nodes.where(lane_id: main_lane.id).sole
    source_head = dag_graph.leaf_nodes.where(lane_id: source_lane.id).sole

    merge_node = nil
    dag_graph.mutate! do |m|
      merge_node = m.merge_lanes!(
        target_lane: main_lane,
        target_from_node: main_head,
        source_lanes_and_nodes: [{ lane: source_lane, from_node: source_head }],
        node_type: Messages::AgentMessage.node_type_key,
        metadata: metadata
      )
    end

    merge_node
  end
end
