class Conversation::ComposerState
  QUEUE_DISPLAY_LIMIT = 4

  def self.build(conversation:, now: Time.current)
    new(conversation: conversation, now: now).to_h
  end

  def initialize(conversation:, now: Time.current)
    @conversation = conversation
    @now = now
  end

  def to_h
    queue_items = queued_candidates
    queue_anchor = queue_anchor_agent

    {
      "running" => running_agent.present?,
      "running_node_id" => queue_anchor&.id&.to_s,
      "running_turn_id" => queue_anchor&.turn_id&.to_s,
      "queue" => {
        "available" => queue_anchor.present?,
        "queued_count" => queue_items.length,
        "display_limit" => QUEUE_DISPLAY_LIMIT,
        "overflow_count" => [queue_items.length - QUEUE_DISPLAY_LIMIT, 0].max,
        "items" => queue_items.first(QUEUE_DISPLAY_LIMIT),
      },
      "steer" => {
        "available" => steer_available?,
        "reason" => steer_reason,
      },
    }
  end

  private

  attr_reader :conversation, :now

  def graph
    @graph ||= conversation.root_graph
  end

  def lane
    @lane ||= conversation.chat_lane
  end

  def running_agent
    @running_agent ||=
      graph.nodes.active
        .where(
          lane_id: lane.id,
          node_type: Messages::AgentMessage.node_type_key,
          state: [DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
        )
        .order(:id)
        .last
  end

  def queued_candidates
    @queued_candidates ||= conversation.queued_turn_items(now: now)
  end

  def queue_anchor_agent
    @queue_anchor_agent ||=
      graph.nodes.active
        .where(
          lane_id: lane.id,
          node_type: Messages::AgentMessage.node_type_key,
          state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
        )
        .order(:id)
        .first
  end

  def steer_policy
    @steer_policy ||= conversation.resolved_input_policy(action: "steer_current_turn")
  end

  def current_user_node
    return nil if running_agent.nil?

    from_node_id =
      graph.edges.active
        .where(to_node_id: running_agent.id, edge_type: DAG::Edge::SEQUENCE)
        .order(:id)
        .pick(:from_node_id)
    return nil if from_node_id.blank?

    graph.nodes.active.find_by(id: from_node_id)
  end

  def steer_available?
    return false unless running_agent.present?
    return false unless steer_policy.fetch("steer_capability")
    return false unless current_user_node&.node_type == Messages::UserMessage.node_type_key
    return false if steer_blocked_by_side_effects?

    true
  end

  def steer_reason
    return "A run must be active before you can queue or steer the next input." if running_agent.nil?
    return "Steering is disabled by the current input policy." unless steer_policy.fetch("steer_capability")
    return "The current turn cannot be steered in place." unless current_user_node&.node_type == Messages::UserMessage.node_type_key
    return "This turn already produced side effects, so steering falls back to a new turn." if steer_blocked_by_side_effects?

    nil
  end

  def steer_blocked_by_side_effects?
    return false if current_user_node.nil?
    return false if steer_policy.fetch("steer_after_side_effects")

    descendant_ids = current_user_node.causal_descendant_ids - [current_user_node.id]
    graph.nodes.active.where(id: descendant_ids, node_type: Messages::Task.node_type_key).exists?
  end
end
