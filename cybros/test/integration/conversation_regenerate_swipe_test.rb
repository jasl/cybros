require "test_helper"

class ConversationRegenerateSwipeTest < ActionDispatch::IntegrationTest
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

  test "regenerate on tail assistant creates a new swipe variant in-place" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    graph = conversation.reload.dag_graph
    first_agent = graph.leaf_nodes.order(:id).last
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Hi v1")

    assert_difference -> { graph.nodes.count }, +1 do
      post "/conversations/#{conversation.id}/regenerate", params: { agent_node_id: first_agent.id }
    end

    assert_response :redirect
    conversation.reload

    versions = graph.nodes.where(version_set_id: first_agent.version_set_id).order(:created_at, :id).to_a
    assert_equal 2, versions.size
    assert_equal 1, versions.count { |n| n.compressed_at.nil? }
  end

  test "regenerate on non-tail assistant auto-branches and redirects" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    # Turn 1
    post conversation_messages_path(conversation), params: { content: "Hello" }
    graph = conversation.reload.dag_graph
    agent1 = graph.leaf_nodes.order(:id).last
    agent1.mark_running!
    agent1.mark_finished!(content: "Hi v1")

    # Turn 2 makes agent1 non-tail
    post conversation_messages_path(conversation), params: { content: "Followup" }
    agent2 = conversation.reload.dag_graph.leaf_nodes.order(:id).last
    agent2.mark_running!
    agent2.mark_finished!(content: "Hi v2")

    assert_difference -> { Conversation.count }, +1 do
      post "/conversations/#{conversation.id}/regenerate", params: { agent_node_id: agent1.id }
    end

    child = Conversation.order(:id).last
    assert_redirected_to conversation_path(child)
    assert_equal "branch", child.kind
    assert_equal agent1.id, child.forked_from_node_id
  end
end
