require "test_helper"

class ConversationMessagesDualChannelTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
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

  test "create returns turbo streams appending user + agent placeholder bubbles" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation),
         params: { content: "Hello" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"

    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    empty_state_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_empty_state)

    assert_includes response.body, "turbo-stream"
    assert_includes response.body, %(turbo-stream action="append" target="#{list_id}")
    assert_includes response.body, %(turbo-stream action="remove" target="#{empty_state_id}")

    # User bubble should render.
    assert_includes response.body, "Hello"

    # Agent placeholder bubble should exist (node_id is dynamic; check by data-role).
    assert_includes response.body, %(data-role="agent-bubble")
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

    DAG::NodeBody.where(id: agent.body_id).update_all(
      output_preview: { "content" => "# Done" },
      updated_at: Time.current,
    )

    get refresh_conversation_messages_path(conversation),
        params: { node_id: agent.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"
    assert_includes response.body, %(turbo-stream action="replace" target="message_#{agent.id}")
    assert_includes response.body, %(data-controller="markdown")
    assert_includes response.body, "# Done"
  end
end
