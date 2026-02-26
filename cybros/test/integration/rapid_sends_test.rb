require "test_helper"

class RapidSendsTest < ActionDispatch::IntegrationTest
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

  test "rapid sends create sequenced user/agent pairs with queue dependency" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")

    5.times do |i|
      post conversation_messages_path(conversation), params: { content: "m#{i + 1}" }
      assert_redirected_to conversation_path(conversation)
    end

    graph = conversation.reload.dag_graph
    nodes = graph.nodes.active.order(:created_at).to_a

    user_nodes = nodes.select { |n| n.node_type == Messages::UserMessage.node_type_key }
    agent_nodes = nodes.select { |n| n.node_type == Messages::AgentMessage.node_type_key }

    assert_equal 5, user_nodes.length
    assert_equal 5, agent_nodes.length

    user_nodes.each_with_index do |user, idx|
      agent = agent_nodes.find { |a| a.turn_id.to_s == user.turn_id.to_s }
      assert agent, "expected an agent node for user turn"

      seq =
        graph.edges.active.where(
          edge_type: DAG::Edge::SEQUENCE,
          from_node_id: user.id,
          to_node_id: agent.id,
        )
      assert seq.exists?, "expected sequence edge user->agent"

      assert_equal "m#{idx + 1}", user.body_input.fetch("content")
    end

    agent_nodes.each_cons(2) do |prev, nxt|
      dep =
        graph.edges.active.where(
          edge_type: DAG::Edge::DEPENDENCY,
          from_node_id: prev.id,
          to_node_id: nxt.id,
        )
      assert dep.exists?, "expected dependency edge between successive agent nodes"
    end
  end
end
