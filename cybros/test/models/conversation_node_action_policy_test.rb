require "test_helper"

class ConversationNodeActionPolicyTest < ActiveSupport::TestCase
  def policy_for(conversation:, node:)
    policy_class =
      begin
        Conversation.const_get(:NodeActionPolicy, false)
      rescue NameError
        nil
      end

    refute_nil policy_class, "expected Conversation::NodeActionPolicy to be defined"

    policy_class.new(conversation: conversation, node: node).to_h
  end

  test "finished tail assistant exposes regenerate in_place and swipe" do
    conversation = create_conversation!
    conversation.append_user_message!(content: "Hello")

    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    policy = policy_for(conversation: conversation, node: agent)

    assert_equal true, policy.dig("actions", "regenerate", "supported")
    assert_equal true, policy.dig("actions", "regenerate", "available")
    assert_equal "in_place", policy.dig("actions", "regenerate", "mode")

    assert_equal true, policy.dig("actions", "swipe", "supported")
    assert_equal true, policy.dig("actions", "swipe", "available")
    assert_equal 1, policy.dig("actions", "swipe", "current")
    assert_equal 1, policy.dig("actions", "swipe", "total")
    assert_equal false, policy.dig("actions", "swipe", "left_available")
    assert_equal false, policy.dig("actions", "swipe", "right_available")

    assert_equal true, policy.dig("actions", "retry", "supported")
    assert_equal false, policy.dig("actions", "retry", "available")
  end

  test "finished tail assistant exposes directional swipe availability for multiple versions" do
    conversation = create_conversation!

    conversation.append_user_message!(content: "Hello")
    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    regen = conversation.regenerate!(agent_node_id: agent.id)
    agent_v2 = regen.fetch(:node)
    agent_v2.mark_running!
    agent_v2.mark_finished!(content: "Hi v2")

    policy = policy_for(conversation: conversation, node: agent_v2)

    assert_equal true, policy.dig("actions", "swipe", "available")
    assert_equal 2, policy.dig("actions", "swipe", "current")
    assert_equal 2, policy.dig("actions", "swipe", "total")
    assert_equal true, policy.dig("actions", "swipe", "left_available")
    assert_equal false, policy.dig("actions", "swipe", "right_available")
  end

  test "finished non-tail assistant hides regenerate and leaves branching as the safe alternative" do
    conversation = create_conversation!

    conversation.append_user_message!(content: "Hello")
    first_agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Hi v1")

    conversation.append_user_message!(content: "Follow up")
    second_agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    second_agent.mark_running!
    second_agent.mark_finished!(content: "Hi v2")

    policy = policy_for(conversation: conversation, node: first_agent)

    assert_equal true, policy.dig("actions", "regenerate", "supported")
    assert_equal false, policy.dig("actions", "regenerate", "available")

    assert_equal true, policy.dig("actions", "swipe", "supported")
    assert_equal false, policy.dig("actions", "swipe", "available")
    assert_equal true, policy.dig("actions", "branch", "supported")
    assert_equal true, policy.dig("actions", "branch", "available")
  end

  test "errored assistant exposes retry but not regenerate" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    user = nil
    agent = nil
    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          metadata: { "error" => "boom" },
        )
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    policy = policy_for(conversation: conversation, node: agent)

    assert_equal true, policy.dig("actions", "retry", "supported")
    assert_equal true, policy.dig("actions", "retry", "available")

    assert_equal true, policy.dig("actions", "regenerate", "supported")
    assert_equal false, policy.dig("actions", "regenerate", "available")
  end

  test "pending assistant exposes stop" do
    conversation = create_conversation!
    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)

    policy = policy_for(conversation: conversation, node: agent)

    assert_equal true, policy.dig("actions", "stop", "supported")
    assert_equal true, policy.dig("actions", "stop", "available")
  end

  test "tail pending assistant exposes start" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    agent = conversation.append_user_message!(content: "Hello").fetch(:agent_node)

    policy = policy_for(conversation: conversation, node: agent)

    assert_equal true, policy.dig("actions", "start", "supported")
    assert_equal true, policy.dig("actions", "start", "available")
  end

  test "non-tail pending assistant does not expose start" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane

    pending_one = nil
    pending_two = nil

    graph.mutate! do |m|
      user_one =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "u1",
          metadata: {},
        )
      pending_one =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )
      user_two =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "u2",
          metadata: {},
        )
      pending_two =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user_one, to_node: pending_one, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: pending_one, to_node: user_two, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user_two, to_node: pending_two, edge_type: DAG::Edge::SEQUENCE)
    end

    policy = policy_for(conversation: conversation, node: pending_one)

    assert_equal true, policy.dig("actions", "start", "supported")
    assert_equal false, policy.dig("actions", "start", "available")
  end

  test "awaiting approval assistant exposes stop" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    agent = nil
    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          content: "Hi",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::AWAITING_APPROVAL,
          lane_id: conversation.chat_lane.id,
          metadata: {},
        )
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    policy = policy_for(conversation: conversation, node: agent)

    assert_equal true, policy.dig("actions", "stop", "supported")
    assert_equal true, policy.dig("actions", "stop", "available")
  end

  test "retry policy respects node can_retry? graph preconditions" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    failed = nil
    downstream = nil
    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      failed =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          metadata: { "error" => "boom" },
        )
      downstream =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          metadata: {},
        )
      m.create_edge(from_node: user_node, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: failed, to_node: downstream, edge_type: DAG::Edge::SEQUENCE)
    end

    refute failed.can_retry?

    policy = policy_for(conversation: conversation, node: failed)
    assert_equal false, policy.dig("actions", "retry", "available")
  end

  test "retry remains available beyond historical retry depth limit" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    user_node = nil
    ancestors = []
    failed = nil

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )

      previous = nil
      5.times do |index|
        node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::STOPPED,
            lane_id: conversation.chat_lane.id,
            retry_of_id: previous&.id,
            metadata: { "error" => "attempt #{index}" },
          )
        ancestors << node
        previous = node
      end

      failed =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          retry_of_id: ancestors.last.id,
          metadata: { "error" => "boom" },
        )

      m.create_edge(from_node: user_node, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
    end

    policy = policy_for(conversation: conversation, node: failed)

    assert_equal true, policy.dig("actions", "retry", "supported")
    assert_equal true, policy.dig("actions", "retry", "available")
  end

  test "latest user message exposes edit and delete but not branch" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    user =
      graph.nodes.create!(
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        body_input: { "content" => "Hi" },
        metadata: {},
      )

    policy = policy_for(conversation: conversation, node: user)

    assert_equal true, policy.dig("actions", "edit", "supported")
    assert_equal true, policy.dig("actions", "edit", "available")

    assert_equal false, policy.dig("actions", "branch", "supported")
    assert_equal false, policy.dig("actions", "branch", "available")

    assert_equal true, policy.dig("actions", "delete", "supported")
    assert_equal true, policy.dig("actions", "delete", "available")
  end

  test "historical user message hides edit even after descendants are finished" do
    conversation = create_conversation!

    first = conversation.append_user_message!(content: "u1")
    first_user = first.fetch(:user_node)
    first_agent = first.fetch(:agent_node)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "a1")

    second = conversation.append_user_message!(content: "u2")
    second_agent = second.fetch(:agent_node)
    second_agent.mark_running!
    second_agent.mark_finished!(content: "a2")

    policy = policy_for(conversation: conversation, node: first_user)

    assert_equal true, policy.dig("actions", "edit", "supported")
    assert_equal false, policy.dig("actions", "edit", "available")
    assert_equal "not_latest_user_message", policy.dig("actions", "edit", "reason")
  end
end
