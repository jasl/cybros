require "test_helper"
require "nokogiri"

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

  test "create while a run is active keeps the queued follow-up out of the message list stream and inside the composer rail stream" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first_result = conversation.append_user_message!(content: "first request")
    first_agent = first_result.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    queued_content = "queued follow up"

    post conversation_messages_path(conversation),
         params: { content: queued_content },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    composer_rail_id = ActionView::RecordIdentifier.dom_id(conversation, :composer_status_rail)

    list_fragment = turbo_stream_template_for(response.body, target: list_id)
    rail_fragment = turbo_stream_template_for(response.body, target: composer_rail_id)

    refute_includes list_fragment, queued_content
    assert_includes rail_fragment, queued_content
    assert_equal ["first request"], visible_user_inputs(conversation)
    assert_equal [queued_content], conversation.composer_state.dig("queue", "items").map { |item| item.fetch("content") }
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

  test "regenerate for the tail assistant returns turbo streams instead of redirecting the page" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    post conversation_messages_path(conversation), params: { content: "Hello" }

    agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    post regenerate_conversation_path(conversation),
         params: { agent_node_id: agent.id },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"

    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    composer_rail_id = ActionView::RecordIdentifier.dom_id(conversation, :composer_status_rail)

    assert_includes response.body, %(turbo-stream action="replace" target="#{list_id}")
    assert_includes response.body, %(turbo-stream action="replace" target="#{composer_rail_id}")
  end

  private

    def turbo_stream_template_for(body, target:)
      fragment = Nokogiri::HTML5.fragment(body)
      stream = fragment.at_css(%(turbo-stream[target="#{target}"]))
      assert_not_nil stream, "expected turbo-stream target=#{target.inspect}"

      template = stream.at_css("template")
      assert_not_nil template, "expected template for turbo-stream target=#{target.inspect}"

      template.inner_html
    end

    def visible_user_inputs(conversation)
      conversation.message_page(limit: 20, mode: :full).fetch("messages").filter_map do |message|
        next unless message.fetch("node_type") == Messages::UserMessage.node_type_key

        message.dig("payload", "input", "content").to_s.presence
      end
    end
end
