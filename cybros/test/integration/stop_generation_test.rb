require "test_helper"

class StopGenerationTest < ActionDispatch::IntegrationTest
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

  test "stop endpoint stops a running agent node" do
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
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent.reload.state

    post stop_conversation_path(conversation), params: { node_id: agent.id }
    assert_response :success
    assert_equal DAG::Node::STOPPED, agent.reload.state
  end

  test "stop endpoint returns unprocessable_entity when node is not running" do
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

    post stop_conversation_path(conversation), params: { node_id: agent.id }
    assert_response :unprocessable_entity
    assert_includes response.body, "node_not_running"
  end
end
