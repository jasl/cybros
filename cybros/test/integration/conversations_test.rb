require "test_helper"

class ConversationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    LLMProviderCredential.delete_all
  end

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

  test "requires authentication" do
    get conversations_path
    assert_redirected_to new_session_path
  end

  test "index lists conversations" do
    user = sign_in_owner!

    a = create_conversation!(user: user, title: "A")
    b = create_conversation!(user: user, title: "B")

    get conversations_path
    assert_response :success
    assert_includes response.body, a.title
    assert_includes response.body, b.title
  end

  test "create redirects to show" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")
    default_agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    default_program = Agents::BootstrapBundledDefaultService.ensure_agent!

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "New convo", agent_id: default_agent.id } }
    end

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation_path(conversation)
    assert_equal "openai/gpt-5.4", conversation.metadata.dig("llm", "model_ref")
    assert_equal "main", conversation.metadata.dig("agent", "key")
    assert_nil conversation.metadata.dig("agent", "agent_profile")
    assert_equal "keep_context", conversation.resolved_input_policy.fetch("interrupted_output_policy")
    assert_nil conversation[:agent_program_id]
    assert_nil conversation[:default_execution_target_id]
  end

  test "create redirects to llm settings when no usable default model exists" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")
    LLMProviderCredential.delete_all
    default_agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    assert_no_difference -> { Conversation.count } do
      post conversations_path, params: { conversation: { title: "New convo", agent_id: default_agent.id } }
    end

    assert_redirected_to system_settings_llm_providers_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "No usable default model is configured."
  end

  test "show renders transcript and message form" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, conversation.title
    assert_includes response.body, "Message…"
    assert_includes response.body, 'name="turbo-refresh-method" content="morph"'
    assert_includes response.body, 'name="turbo-refresh-scroll" content="preserve"'
  end

  test "show renders hard-oversize product messages in the transcript" do
    user = sign_in_owner!

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "oversize" => {
              "single_message" => {
                "soft_threshold_ratio" => 0.00005,
                "hard_threshold_ratio" => 0.0002,
              },
            },
          },
        },
      )

    conversation.append_user_message!(content: "y" * 200)

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "This input is too large for a single turn."
  end

  test "stop accepts pending agent nodes" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent.id)

    post stop_conversation_path(conversation), params: { node_id: agent.id }, as: :json

    assert_response :success
    assert_equal DAG::Node::STOPPED, agent.reload.state
    assert_equal "canceled", run.reload.state
  end

  test "stop returns not found for nodes outside the conversation lane" do
    user = sign_in_owner!
    root = create_conversation!(user: user, title: "Root")

    first_turn = root.append_user_message!(content: "Hello")
    first_agent = first_turn.fetch(:agent_node)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Done")

    branch = root.create_child!(from_node_id: first_agent.id, kind: "branch", title: "Branch", user_content: "What if?")
    second_turn = root.append_user_message!(content: "Root followup")
    root_agent = second_turn.fetch(:agent_node)
    root_agent.mark_running!

    post stop_conversation_path(branch), params: { node_id: root_agent.id }, as: :json

    assert_response :not_found
    assert_equal DAG::Node::RUNNING, root_agent.reload.state
  end

  test "show renders awaiting approval agent bubbles in the transcript" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    result = conversation.append_user_message!(content: "Need approval")
    agent = result.fetch(:agent_node)
    agent.body.update!(output_preview: {})
    agent.park_for_approval!

    get conversation_path(conversation)

    assert_response :success
    assert_select %(#message_#{agent.id} [data-role="agent-bubble"][data-node-state="awaiting_approval"]), count: 1
    assert_includes response.body, "Approve"
  end

  test "show renders composer model picker below input without visible model label or provider prefix" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "codex_subscription", credential_type: "oauth_codex", refresh_token: "rt")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "codex_subscription/gpt-5.3-codex" },
        },
      )

    get conversation_path(conversation)
    assert_response :success

    assert_match(/data-testid="conversation-composer-input".*data-testid="conversation-composer-footer"/m, response.body)
    refute_match(/>\s*Model\s*</, response.body)
    refute_includes response.body, "Codex (ChatGPT Pro/Plus) · GPT‑5.3 Codex"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"][aria-label="Model"]'
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] option[selected]', text: "GPT‑5.3 Codex"
  end

  test "index no longer renders a generic new conversation form" do
    user = sign_in_owner!
    create_conversation!(user: user, title: "Existing")

    get conversations_path
    assert_response :success

    refute_includes response.body, "New conversation title"
    refute_includes response.body, ">New<"
  end

  test "creating a conversation requires an explicit agent_id" do
    user = sign_in_owner!

    assert_no_difference -> { Conversation.count } do
      post conversations_path, params: { conversation: { title: "Missing agent" } }
    end

    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "agent"
    assert_equal 0, user.conversations.count
  end

  test "creating a conversation binds the requested agent" do
    user = sign_in_owner!
    agent = create_selectable_agent!(name: "Review agent")

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "Agent launch", agent_id: agent.id } }
    end

    conversation = Conversation.order(:id).last
    assert_redirected_to conversation_path(conversation)
    assert_equal agent.id, conversation.agent_id
    assert_nil conversation[:agent_program_id]
    assert_nil conversation[:default_execution_target_id]
  end

  test "show renders the composer form as multipart so file attachments reach Rails" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    get conversation_path(conversation)
    assert_response :success

    assert_select "form##{ActionView::RecordIdentifier.dom_id(conversation, :message_form)}[enctype='multipart/form-data']"
    assert_select "form##{ActionView::RecordIdentifier.dom_id(conversation, :message_form)} input[type='file'][name='attachments[]'][multiple]"
  end

  test "show includes a hidden coalescing override so rapid follow-ups become queued turns" do
    user = sign_in_owner!
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

    get conversation_path(conversation)
    assert_response :success

    assert_select 'input[type="hidden"][name="input_policy_override[input_coalescing][enabled]"][value="false"]', count: 1
  end

  test "show renders a single queued message inline without an expand toggle" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph

    first = conversation.append_user_message!(content: "first request")
    first_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)

    conversation.append_user_message!(content: "queued follow up 1")

    get conversation_path(conversation)
    assert_response :success

    assert_select '[data-testid="conversation-queued-alert"]', count: 1
    assert_select '[data-testid="conversation-queued-alert-primary-item"]', count: 1, text: /queued follow up 1/
    assert_select '[data-testid="conversation-queued-alert-toggle"]', count: 0
    assert_select '[data-testid="conversation-queued-alert-overflow-item"]', count: 0
  end

  test "show renders the first queued message inline and only expands the remaining queued items" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph

    first = conversation.append_user_message!(content: "first request")
    first_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)

    5.times do |index|
      conversation.append_user_message!(content: "queued follow up #{index + 1}")
    end

    get conversation_path(conversation)
    assert_response :success

    assert_match(/data-testid="conversation-composer-status-rail".*data-testid="conversation-composer-input"/m, response.body)
    refute_includes response.body, "Queue next turn"
    refute_includes response.body, "Candidate next-input preview"
    assert_select '[data-testid="conversation-queued-alert"]', count: 1
    assert_select '[data-testid="conversation-queued-alert-primary-item"]', count: 1, text: /queued follow up 1/
    assert_select '[data-testid="conversation-queued-alert-toggle"]', count: 1
    assert_select '[data-testid="conversation-queued-alert-overflow-item"]', count: 3
    assert_select '[data-testid="conversation-queued-alert-overflow-item"]', text: /queued follow up 2/
    assert_select '[data-testid="conversation-queued-alert-overflow-item"]', text: /queued follow up 4/
    assert_select 'input[type="hidden"][name="interrupted_output_policy_override"]', count: 1
  end

  test "start claims the tail pending assistant and enqueues execution" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    agent = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
    clear_enqueued_jobs

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [agent.id]) do
      post start_conversation_path(conversation), params: { node_id: agent.id }, as: :json
    end

    assert_response :success
    assert_equal DAG::Node::RUNNING, agent.reload.state
  end

  test "show keeps stale model selection in reselect state instead of auto-falling back" do
    user = sign_in_owner!
    LLMProviderCredential.delete_all

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "Selected model is no longer available. Please reselect a model."
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] option[selected]', text: "Please reselect a model"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"][required]'
  end

  test "show uses resolved default model instead of first picker option when conversation has no stored model_ref" do
    user = sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
        },
      )

    get conversation_path(conversation)
    assert_response :success
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] option[selected]', text: "GPT‑5.4"
  end

  test "show groups model picker options by provider with plain model labels inside each group" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "codex_subscription", credential_type: "oauth_codex", refresh_token: "rt")
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-openrouter")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    get conversation_path(conversation)
    assert_response :success

    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] optgroup[label="Codex (ChatGPT Pro/Plus)"] option', text: "GPT‑5.3 Codex"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] optgroup[label="OpenAI"] option', text: "GPT‑5.4"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] optgroup[label="OpenRouter"] option', text: "GPT‑5.4"
    refute_includes response.body, "GPT‑5.4 (OpenAI)"
    refute_includes response.body, "GPT‑5.4 (OpenRouter)"
  end

  test "show requires reselection when default model is unusable and conversation has no stored model_ref" do
    user = sign_in_owner!
    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")
    LLMProviderCredential.delete_all

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
        },
      )

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "Default model is not currently usable. Please reselect a model or fix credentials."
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] option[selected]', text: "Please reselect a model"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"][required]'
  end

  test "show keeps duplicate model names separated by provider groups" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-openrouter")

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    get conversation_path(conversation)
    assert_response :success
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] optgroup[label="OpenAI"] option', text: "GPT‑5.4"
    assert_select 'select[name="model_ref"][data-testid="conversation-composer-model-picker"] optgroup[label="OpenRouter"] option', text: "GPT‑5.4"
  end

  test "create prefers the selected program manifest over the site default model" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-test")
    default_agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    Account.instance.update_llm_default_model_ref!("openrouter/openai-gpt-5.4-pro")

    assert_difference -> { Conversation.count }, +1 do
      post conversations_path, params: { conversation: { title: "Chat", agent_id: default_agent.id } }
    end

    conversation = Conversation.order(:created_at).last
    assert_equal user.id, conversation.user_id
    assert_equal "openai/gpt-5.4", conversation.metadata.dig("llm", "model_ref")
    assert_nil conversation[:agent_program_id]
    assert_nil conversation[:default_execution_target_id]
  end

  test "create_message appends a finished user_message and leaves a pending agent_message leaf" do
    user = sign_in_owner!
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    conversation = create_conversation!(user: user, title: "Chat")

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

  private

    def create_selectable_agent!(name:)
      program =
        create_agent_record!(
          name: name,
          config_namespace: "fixture.conversations.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_program_key" => SecureRandom.hex(4), "name" => name },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = build_default_execution_profile!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment = create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
      agent
    end
end
