require "test_helper"

class ConversationMessagesDualChannelTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
    LLMProvider.delete_all
    ConversationRun.delete_all
    Event.delete_all
    Conversation.delete_all
    Session.delete_all
    User.delete_all
    Identity.delete_all

    DAG::NodeEvent.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodeBody.delete_all
    DAG::Graph.delete_all
  end

  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "create returns turbo streams replacing the message list and composer rail" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation),
         params: { content: "Hello" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"

    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    empty_state_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_empty_state)
    composer_rail_id = ActionView::RecordIdentifier.dom_id(conversation, :composer_status_rail)

    assert_includes response.body, "turbo-stream"
    assert_includes response.body, %(turbo-stream action="replace" target="#{list_id}")
    assert_includes response.body, %(turbo-stream action="replace" target="#{composer_rail_id}")
    assert_includes response.body, %(turbo-stream action="remove" target="#{empty_state_id}")

    # User bubble should render.
    assert_includes response.body, "Hello"

    # Agent placeholder bubble should exist (node_id is dynamic; check by data-role).
    assert_includes response.body, %(data-role="agent-bubble")
  end

  test "create returns 422 when preferred model is unavailable" do
    LLMProvider.delete_all

    user = create_user!
    sign_in!(user)

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "agent_program" => { "model_prefer" => ["m1"] },
          },
        },
      )

    post conversation_messages_path(conversation),
         params: { content: "Hello" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Preferred model is unavailable"
  end

  test "create honors nested input policy override params from the composer form" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation),
         params: {
           content: "Hello",
           input_policy_override: {
             input_coalescing: { window_ms: 0 },
           },
         },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    agent = conversation.root_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).order(:id).last
    assert_not_nil agent
    assert_nil agent.claim_after_at
  end

  test "create returns 422 when selected model_ref is invalid" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation),
         params: { content: "Hello", model_ref: "openai/does-not-exist" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Selected model is no longer available"
  end

  test "create with blank content returns no-content for turbo and creates no messages" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")

    assert_difference "DAG::Node.count", 0 do
      post conversation_messages_path(conversation),
           params: { content: "   " },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :no_content
  end

  test "refresh returns turbo stream replacing a terminal agent message wrapper" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: "finished",
          metadata: {},
        )
    end

    agent.body.apply_finished_content!("# Done")
    agent.body.save!

    get refresh_conversation_messages_path(conversation),
        params: { node_id: agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"
    assert_includes response.body, %(turbo-stream action="replace" target="message_#{agent.id}")
    assert_includes response.body, %(data-controller="markdown")
    assert_includes response.body, "# Done"
  end

  test "refresh returns not found for a node outside the conversation lane" do
    user = create_user!
    sign_in!(user)

    root = create_conversation!(user: user, title: "Root")
    first_turn = root.append_user_message!(content: "Hello")
    first_agent = first_turn.fetch(:agent_node)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Done")

    branch = root.create_child!(from_node_id: first_agent.id, kind: "branch", title: "Branch", user_content: "What if?")
    root_turn = root.append_user_message!(content: "Root followup")
    root_agent = root_turn.fetch(:agent_node)

    get refresh_conversation_messages_path(branch),
        params: { node_id: root_agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :not_found
  end
end
