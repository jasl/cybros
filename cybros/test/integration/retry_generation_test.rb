require "test_helper"

class RetryGenerationTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "retry endpoint creates a new agent node and queues a run" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_difference -> { ConversationRun.count }, +1 do
      post retry_conversation_path(conversation), params: { node_id: agent.id }
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["node_id"].present?
    new_node = DAG::Node.find(body["node_id"])
    assert_equal Messages::AgentMessage.node_type_key, new_node.node_type
    assert_equal DAG::Node::PENDING, new_node.state
    assert_equal user.turn_id, new_node.turn_id
  end

  test "retry endpoint rejects non-agent nodes" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user = nil
    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
    end

    post retry_conversation_path(conversation), params: { node_id: user.id }
    assert_response :unprocessable_entity
    assert_includes response.body, "not_an_agent_node"
  end

  test "retry endpoint rejects non-retryable states" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    post retry_conversation_path(conversation), params: { node_id: agent.id }
    assert_response :unprocessable_entity
    assert_includes response.body, "not_retryable"
  end

  test "retry endpoint rejects when retry already queued" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user = nil
    failed = nil
    queued_retry = nil

    graph.mutate! do |m|
      user =
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
          metadata: {},
        )
      queued_retry =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "retry_of_node_id" => failed.id },
        )

      m.create_edge(from_node: user, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: queued_retry, edge_type: DAG::Edge::SEQUENCE)
    end

    post retry_conversation_path(conversation), params: { node_id: failed.id }
    assert_response :conflict
    assert_includes response.body, "retry_already_queued"
  end
end
