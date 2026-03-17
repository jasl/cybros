require "test_helper"
require "nokogiri"

class ConversationMessagesDualChannelTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
    ActiveRecord::Base.lease_connection.disable_referential_integrity do
      LLMProviderCredential.delete_all
      AgentRPCOperationReceipt.delete_all
      AgentRPCInvocation.delete_all
      AgentRPCSession.delete_all
      RunDraft.delete_all
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

  test "create falls back to the site default when preferred model is unavailable" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "dev", credential_type: "api_key", api_key: "sk-dev")
    Account.instance.update_llm_default_model_ref!("dev/mock-model")

    user = create_user!
    sign_in!(user)

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "model_prefer" => ["m1"],
          },
        },
      )

    post conversation_messages_path(conversation),
         params: { content: "Hello" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "dev/mock-model", conversation.reload.metadata.dig("llm", "model_ref")
    assert_includes response.body, %(data-role="agent-bubble")
  end

  test "create promotes composer draft settings for the next turn and clears the draft" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )
    conversation.update!(permission_mode: "default")
    conversation.update_composer_draft!(
      content: "Use the saved draft",
      model_ref: "dev/mock-model",
      permission_mode: "conservative",
    )

    post conversation_messages_path(conversation),
         params: { content: "Use the saved draft" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    conversation.reload
    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)

    assert_equal "conservative", conversation.permission_mode
    assert_equal "dev/mock-model", conversation.metadata.dig("llm", "model_ref")
    assert_equal({}, conversation.composer_draft)
    assert_equal "dev/mock-model", agent.metadata.dig("llm", "model_ref")
  end

  test "create applies the submitted permission mode even when the composer draft has not persisted yet" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )
    conversation.update!(permission_mode: "default", composer_draft: {})

    post conversation_messages_path(conversation),
         params: {
           content: "Send right after changing permissions",
           conversation: { permission_mode: "conservative" },
         },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    conversation.reload
    run_draft = RunDraft.order(:created_at).last

    assert_not_nil run_draft
    assert_equal "conservative", conversation.permission_mode
    assert_equal "conservative", run_draft.permission_mode
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

  test "create returns 422 when the selected agent runtime is no longer active and healthy" do
    user = create_user!
    sign_in!(user)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    unavailable_agent =
      create_agent!(
        name: "Unavailable agent",
        config_namespace: "fixture.unavailable.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        manifest_snapshot: { "name" => "Unavailable agent" },
        transport_kind: "http_jsonrpc",
        endpoint_url: "https://example.test/#{SecureRandom.hex(4)}",
        deployment_bearer_secret_ref: "secret://#{SecureRandom.hex(4)}",
        deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
        status: "inactive",
        health_status: "unhealthy",
        protocol_version: "agent_rpc.v1",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        activated_at: Time.current.change(usec: 0),
      )
    conversation = create_conversation!(user: user, title: "Chat", agent: unavailable_agent)
    conversation.update!(agent_config_schema_fingerprint: unavailable_agent.config_schema_fingerprint)

    assert_no_difference -> { RunDraft.count } do
      post conversation_messages_path(conversation),
           params: { content: "Hello" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Selected agent has no active healthy runtime binding."
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

  test "refresh best-effort returns no content for a node outside the conversation lane" do
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
        headers: {
          "Accept" => "text/vnd.turbo-stream.html",
          "X-Cybros-Best-Effort" => "1",
        }

    assert_response :no_content
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
