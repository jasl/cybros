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

  test "model_resolution_for uses site default model and retains agent prefer as metadata" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")
    ensure_llm_provider!(provider_key: "codex_subscription", credential_type: "oauth_codex", refresh_token: "rt")
    Account.instance.update_llm_default_model_ref!("codex_subscription/gpt-5.4")
    program =
      create_agent_record!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Fixture Program",
          "model" => { "prefer" => ["openai/gpt-5.4"] },
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
        agent: program,
      )
    resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation)

    assert_equal "codex_subscription", resolution.fetch(:provider_key)
    assert_equal "gpt-5.4", resolution.fetch(:model_key)
    assert_equal "codex_subscription/gpt-5.4", resolution.fetch(:model_ref)
    assert_equal "gpt-5.4", resolution.fetch(:model)
    assert_equal ["openai/gpt-5.4"], resolution.fetch(:preferred_models)
    assert_equal true, resolution.fetch(:matched_preference)
  end

  test "model_resolution_for does not hard-error when agent prefer is unavailable and a site default exists" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "dev", credential_type: "api_key", api_key: "sk-dev")
    Account.instance.update_llm_default_model_ref!("dev/mock-model")
    program =
      create_agent_record!(
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
        agent: program,
      )

    resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation)

    assert_equal "dev", resolution.fetch(:provider_key)
    assert_equal "mock-model", resolution.fetch(:model_key)
    assert_equal "dev/mock-model", resolution.fetch(:model_ref)
    assert_equal ["codex_subscription/gpt-5.3-codex"], resolution.fetch(:preferred_models)
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
      create_agent_record!(
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
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation)
    agent = create_agent_runtime!(program: program, execution_target: build_default_execution_profile!, deployment: deployment)
    conversation.update!(agent: agent, agent_config_schema_fingerprint: program.config_schema_fingerprint)
    recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: node.id,
        agent: agent,
        recognized_deployment: recognized_deployment,
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
            "planning" => { "step_plan" => { "fixture" => true } },
          },
        },
      ),
    )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

    assert_equal "programmable_agent", runtime.provider.name
    assert_equal "openai/gpt-5.4", runtime.provider.model_ref
    assert_equal "gpt-5.4", runtime.model
  end

  test "runtime_for uses materialized conversation run permission mode for delegated tools" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    program =
      create_agent_record!(
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
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation)
    agent = create_agent_runtime!(program: program, execution_target: build_default_execution_profile!, deployment: deployment)
    conversation.update!(agent: agent, agent_config_schema_fingerprint: program.config_schema_fingerprint)
    recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
    create_conversation_run!(
      conversation: conversation,
      dag_node_id: node.id,
      agent: agent,
      recognized_deployment: recognized_deployment,
      selected_model_ref: "openai/gpt-5.4",
      effective_permission_mode: "full_access",
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
          "planning" => { "step_plan" => { "fixture" => true } },
        },
      },
    )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    decision =
      runtime.tool_policy.authorize(
        name: "subagent_run",
        arguments: { "name" => "worker", "prompt" => "inspect" },
        context: AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new),
      )

    assert_equal :allow, decision.outcome
  end

  test "runtime_for allows kernel-owned bootstrap tasks without a materialized conversation run" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")
    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")

    program = Agents::BootstrapBundledDefaultService.ensure_agent!
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "key" => "main" },
        },
        agent_program: program,
      )

    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    task_node = nil

    graph.mutate!(turn_id: turn_id, kick: false) do |m|
      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: conversation.chat_lane.id,
          metadata: {},
          body_input: {
            "logical_tool_name" => "cybros_seed_message",
            "requested_name" => "cybros_seed_message",
            "name" => "cybros_seed_message",
            "tool_call_id" => "bootstrap-task-1",
            "arguments" => { "content" => "hello from bootstrap" },
            "arguments_summary" => "{\"content\":\"hello from bootstrap\"}",
          },
        )
    end

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: task_node)

    assert runtime.tools_registry.include?("cybros_seed_message")
    assert_equal "gpt-5.4", runtime.model
  end

  test "runtime_for reuses the same-turn programmable run for task nodes" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    program =
      create_agent_record!(
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
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {
          "capability_registry_snapshot_id" => "csnap_fixture",
        },
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )

    conversation = create_conversation!
    agent_node = build_pending_agent_node(conversation: conversation)
    agent = create_agent_runtime!(program: program, execution_target: build_default_execution_profile!, deployment: deployment)
    conversation.update!(agent: agent, agent_config_schema_fingerprint: program.config_schema_fingerprint)
    recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: agent_node.id,
        agent: agent,
        recognized_deployment: recognized_deployment,
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
        "capability_snapshot" => {
          "capability_registry_snapshot_id" => "csnap_fixture",
        },
        "draft" => {
          "id" => SecureRandom.uuid,
          "planning" => {
            "tool_surface" => {
              "capability_registry_snapshot_id" => "csnap_fixture",
              "selected_tool_ids" => [],
            },
          },
        },
        },
      ),
    )
    task_node =
      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::PENDING,
        lane_id: conversation.chat_lane.id,
        turn_id: agent_node.turn_id,
        metadata: {},
        body_input: {
          "logical_tool_name" => "compact_context",
          "requested_name" => "compact_context",
          "effective_tool_id" => "etool_compact",
          "implementation_source" => "agent",
          "implementation_ref" => "agent://compact_context",
          "capability_registry_snapshot_id" => "csnap_fixture",
          "tool_surface_id" => "surface_fixture",
          "tool_call_id" => "tc_1",
          "arguments" => { "reason" => "test" },
          "arguments_summary" => "{\"reason\":\"test\"}",
        },
      )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: task_node)

    assert_equal "programmable_agent", runtime.provider.name
    assert_equal "openai/gpt-5.4", runtime.provider.model_ref
    assert_equal "csnap_fixture", runtime.execution_context_attributes.dig(:cybros, :capability_snapshot, "capability_registry_snapshot_id")
    assert_equal "csnap_fixture", runtime.execution_context_attributes.dig(:cybros, :tool_surface, "capability_registry_snapshot_id")
  end

  test "runtime_for uses pinned effective agent llm options from the materialized conversation run" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    program =
      create_agent_record!(
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
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation)
    agent = create_agent_runtime!(program: program, execution_target: build_default_execution_profile!, deployment: deployment)
    conversation.update!(agent: agent, agent_config_schema_fingerprint: program.config_schema_fingerprint)
    recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: node.id,
        agent: agent,
        recognized_deployment: recognized_deployment,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {
          "llm_options" => {
            "stream" => false,
            "temperature" => 0.1,
          },
        },
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
            "planning" => { "step_plan" => { "fixture" => true } },
          },
        },
      ),
    )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

    assert_equal false, runtime.llm_options.fetch(:stream)
    assert_equal 0.1, runtime.llm_options.fetch(:temperature)
  end

  test "runtime_for ignores missing or zero provider hard caps when computing the effective context window" do
    {
      "missing" => nil,
      "zero" => 0,
    }.each do |label, provider_context_window_tokens|
      with_catalog_yaml(
        <<~YAML
          version: 1
          default_model_ref: "dev/mock-model"
          providers:
            dev:
              display_name: "Dev"
              enabled: true
              adapter_key: "dev"
              base_url: "http://localhost:3000/mock_llm/v1"
              headers: {}
              requires_credential: false
              wire_api: "chat_completions"
              transport: "http"
#{provider_context_window_tokens.nil? ? "" : "              context_window_tokens: #{provider_context_window_tokens}\n"}              models:
                mock-model:
                  display_name: "Mock"
                  api_model: "mock-model"
                  context_window_tokens: 20000
                  context_soft_limit_ratio: 0.5
                  capabilities: { protocol: "chat_completions", tools: { tool_calling: true } }
        YAML
      ) do
        conversation =
          create_conversation!(
            metadata: {
              "agent" => { "agent_profile" => "coding" },
              "llm" => { "model_ref" => "dev/mock-model" },
            },
          )
        node = build_pending_agent_node(conversation: conversation)

        runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

        assert_equal 20000, runtime.context_window_tokens, "#{label} provider cap should not reduce effective hard cap"
        assert_equal 20000, runtime.model_context_window_tokens
        if provider_context_window_tokens.nil?
          assert_nil runtime.provider_context_window_tokens
        else
          assert_equal provider_context_window_tokens, runtime.provider_context_window_tokens
        end
        assert_equal 0.5, runtime.context_soft_limit_ratio
      end
    end
  end

  private

    def with_catalog_yaml(yaml)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "providers.test.yml")
        File.write(path, yaml)

        singleton = Cybros::LLM::Catalog.singleton_class
        singleton.alias_method :__agent_runtime_resolver_llm_provider_test_original_resolve_sources, :resolve_sources
        singleton.define_method(:resolve_sources) { [path] }

        begin
          Cybros::LLM::Catalog.reload!
          yield
        ensure
          singleton.alias_method :resolve_sources, :__agent_runtime_resolver_llm_provider_test_original_resolve_sources
          singleton.remove_method :__agent_runtime_resolver_llm_provider_test_original_resolve_sources
          Cybros::LLM::Catalog.reload!
        end
      end
    end
end
