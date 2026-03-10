require "test_helper"

class Cybros::AgentRuntimeResolverLlmProviderTest < ActiveSupport::TestCase
  setup do
    RunDraft.delete_all
    ConversationRun.delete_all
  end

  def with_env(values)
    prior = {}
    values.each do |key, value|
      prior[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    prior.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def build_pending_agent_node(conversation:)
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    node = nil
    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: node, edge_type: DAG::Edge::SEQUENCE)
    end

    node
  end

  test "model_resolution_for selects model_ref preference from the selected agent program manifest" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")
    ensure_llm_provider!(provider_key: "dev", credential_type: "api_key", api_key: "sk-dev")
    program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "key" => "main" },
        },
        agent_program: program,
      )
    resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation)

    assert_equal "openai", resolution.fetch(:provider_key)
    assert_equal "gpt-5.4", resolution.fetch(:model_key)
    assert_equal "openai/gpt-5.4", resolution.fetch(:model_ref)
    assert_equal "gpt-5.4", resolution.fetch(:model)
  end

  test "model_resolution_for hard-errors when the selected agent program manifest prefers an unavailable provider" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "dev", credential_type: "api_key", api_key: "sk-dev")
    program =
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Fixture Program",
          "model" => { "prefer" => ["codex_subscription/gpt-5.3-codex"] },
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )

    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "key" => "main" },
        },
        agent_program: program,
      )

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation) }
    assert_equal "cybros.llm.model_preference_unavailable", error.code
  end

  test "runtime_for uses site default when agent prefer is absent" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-or-test")
    Account.instance.update_llm_default_model_ref!("openrouter/openai-gpt-5.4")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    assert_equal "openai/gpt-5.4", runtime.model
  end

  test "runtime_for falls back to catalog default when site default no longer exists" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")
    Account.instance.update_llm_default_model_ref!("openai/does-not-exist")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    assert_equal "gpt-5.4", runtime.model
  end

  test "runtime_for hard-errors when site default exists but is not currently usable" do
    LLMProviderCredential.delete_all
    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
    assert_equal "cybros.llm.credential_missing", error.code
  end

  test "runtime_for selects programmable turn compose provider when a materialized programmable run exists" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    program =
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    deployment =
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: "contract:v1",
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation)
    ConversationRun.create!(
      conversation: conversation,
      dag_node_id: node.id,
      state: "queued",
      queued_at: Time.current.change(usec: 0),
      snapshot_version: 1,
      initiated_by_user: conversation.user,
      effective_permission_mode: "default",
      agent_program: program,
      contract_fingerprint: "contract:v1",
      agent_deployment: deployment,
      deployment_fingerprint: "fixture-deployment-v1",
      deployment_activated_at: deployment.activated_at,
      selected_model_ref: "openai/gpt-5.4",
      effective_public_settings: {},
      effective_agent_config: {},
      agent_config_schema_fingerprint: program.config_schema_fingerprint,
      effective_policy: {},
      runtime_governors: {
        "provider_limiter" => {
          "provider_key" => "openai",
        },
      },
      snapshot: {
        "draft" => {
          "id" => SecureRandom.uuid,
          "prepared_plan" => { "fixture" => true },
        },
      },
    )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

    assert_equal "programmable_agent", runtime.provider.name
    assert_equal "openai/gpt-5.4", runtime.provider.model_ref
    assert_equal "gpt-5.4", runtime.model
  end
end
