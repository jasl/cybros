require "test_helper"

class ConversationsTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    identity
  end

  test "requires authentication" do
    get conversations_path
    assert_redirected_to new_session_path
  end

  test "index lists conversations" do
    sign_in_owner!

    a = Conversation.create!(title: "A", metadata: { "agent" => { "agent_profile" => "coding" } })
    b = Conversation.create!(title: "B", metadata: { "agent" => { "agent_profile" => "coding" } })

    get conversations_path
    assert_response :success
    assert_includes response.body, a.title
    assert_includes response.body, b.title
  end

  test "create redirects to show" do
    sign_in_owner!

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "New convo" } }
    end

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation_path(conversation)
  end

  test "show renders transcript and message form" do
    sign_in_owner!

    conversation = Conversation.create!(title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, conversation.title
    assert_includes response.body, "Send"
  end

  test "create_message appends a finished user_message and leaves a pending agent_message leaf" do
    sign_in_owner!

    conversation = Conversation.create!(title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })

    assert_difference -> { conversation.dag_graph.nodes.count }, +2 do
      assert_difference -> { ConversationRun.count }, +1 do
        post conversation_messages_path(conversation), params: { content: "Hello" }
      end
    end

    conversation.reload
    graph = conversation.dag_graph

    user = graph.nodes.active.where(node_type: Messages::UserMessage.node_type_key).order(:created_at).last
    agent = graph.leaf_nodes.order(:created_at).last

    assert user, "expected a user_message node"
    assert agent, "expected a leaf node"

    assert_equal "Hello", user.body_input.fetch("content")
    assert_equal DAG::Node::FINISHED, user.state

    assert_equal Messages::AgentMessage.node_type_key, agent.node_type
    assert_equal DAG::Node::PENDING, agent.state
    assert_equal user.turn_id, agent.turn_id

    run = ConversationRun.order(:created_at).last
    assert_equal conversation.id, run.conversation_id
    assert_equal agent.id, run.dag_node_id
    assert_equal "queued", run.state
    assert run.queued_at
  end
end
