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

    assert_equal true, policy.dig("actions", "retry", "supported")
    assert_equal false, policy.dig("actions", "retry", "available")
  end

  test "finished non-tail assistant exposes regenerate in branch mode and disables swipe" do
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
    assert_equal true, policy.dig("actions", "regenerate", "available")
    assert_equal "branch", policy.dig("actions", "regenerate", "mode")

    assert_equal true, policy.dig("actions", "swipe", "supported")
    assert_equal false, policy.dig("actions", "swipe", "available")
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

  test "user message exposes edit, branch, and delete actions" do
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

    assert_equal true, policy.dig("actions", "branch", "supported")
    assert_equal true, policy.dig("actions", "branch", "available")

    assert_equal true, policy.dig("actions", "delete", "supported")
    assert_equal true, policy.dig("actions", "delete", "available")
  end
end
