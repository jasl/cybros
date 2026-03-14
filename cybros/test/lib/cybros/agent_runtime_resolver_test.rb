require "test_helper"

class Cybros::AgentRuntimeResolverTest < ActiveSupport::TestCase
  test "channel_for reads conversation routing.channel" do
    conversation =
      create_conversation!(
        metadata: {
          "routing" => { "channel" => "web" },
          "agent" => { "agent_profile" => "coding" },
        },
      )

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

    assert_equal "web", Cybros::AgentRuntimeResolver.channel_for(node: node)
  end

  test "channel_for prefers node routing.channel over conversation default" do
    conversation =
      create_conversation!(
        metadata: {
          "routing" => { "channel" => "web" },
          "agent" => { "agent_profile" => "coding" },
        },
      )

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
          metadata: { "routing" => { "channel" => "slack" } },
        )

      m.create_edge(from_node: user, to_node: node, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_equal "slack", Cybros::AgentRuntimeResolver.channel_for(node: node)
  end

  test "channel_for returns nil for empty or invalid routing metadata" do
    conversation =
      create_conversation!(
        metadata: {
          "routing" => "wat",
          "agent" => { "agent_profile" => "coding" },
        },
      )

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
          metadata: { "routing" => { "channel" => "" } },
        )

      m.create_edge(from_node: user, to_node: node, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_nil Cybros::AgentRuntimeResolver.channel_for(node: node)
  end

  test "agent_profile hash applies prompt and tool restrictions" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => {
              "base" => "coding",
              "prompt_mode" => "minimal",
              "memory_search_limit" => 0,
              "tools_allowed" => ["memory_*"],
              "directives_enabled" => true,
              "repo_docs_enabled" => false,
              "context_turns" => 12,
            },
          },
        },
      )

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

    runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    assert_equal :minimal, runtime.prompt_mode
    assert_equal 0, runtime.memory_search_limit
    assert_equal 12, runtime.context_turns
    assert_equal [], runtime.prompt_injection_sources
    assert_equal({}, runtime.directives_config)

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

    denied = runtime.tool_policy.authorize(name: "subagent_spawn", arguments: {}, context: ctx)
    assert denied.denied?
    assert_equal "tool_not_in_profile", denied.reason

    allowed = runtime.tool_policy.authorize(name: "memory_search", arguments: {}, context: ctx)
    assert allowed.allowed?
  end

  test "rejects unknown agent_profile string" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "wat",
          },
        },
      )

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

    err =
      assert_raises(AgentCore::ValidationError) do
        Cybros::AgentRuntimeResolver.runtime_for(
          node: node,
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      end

    assert_equal "cybros.agent_runtime_resolver.agent_profile_must_be_one_of", err.code
  end

  test "rejects invalid context_turns metadata" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "context_turns" => "abc",
          },
        },
      )

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

    err =
      assert_raises(AgentCore::ValidationError) do
        Cybros::AgentRuntimeResolver.runtime_for(
          node: node,
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      end

    assert_equal "cybros.agent_runtime_resolver.context_turns_must_be_an_integer", err.code
  end

  test "agent_profile runtime_surface config builds runner and normalized execution context attributes" do
    node =
      build_pending_agent_node(
        metadata: {
          "routing" => { "channel" => "web" },
          "agent" => {
              "agent_profile" => {
                "base" => "coding",
                "runtime_surface" => {
                  "type" => "noop",
                  "helpers" => { "estimate_tokens" => true, "estimate_messages" => true },
                  "stage_limits" => {
                    "prepare_turn" => { "timeout_s" => 0.5, "max_output_bytes" => 2048 },
                  },
                },
            },
          },
        },
      )

    runtime = build_runtime_for(node)

    assert_instance_of AgentCore::RuntimeSurface::Base, runtime.runtime_surface
    assert_instance_of AgentCore::RuntimeSurface::Runner, runtime.runtime_surface_runner
    assert_equal(
      {
        type: :noop,
        helpers: [:estimate_messages, :estimate_tokens],
        stage_limits: {
          prepare_turn: { timeout_s: 0.5, max_output_bytes: 2048 },
        },
      },
      runtime.execution_context_attributes.fetch(:runtime_surface),
    )
  end

  test "missing or invalid runtime_surface config resolves to default noop runtime surface" do
    missing_node =
      build_pending_agent_node(
        metadata: {
          "agent" => {
            "agent_profile" => {
              "base" => "coding",
            },
          },
        },
      )
    invalid_node =
      build_pending_agent_node(
        metadata: {
          "agent" => {
            "agent_profile" => {
              "base" => "coding",
              "runtime_surface" => {
                "type" => "wat",
                "helpers" => { "estimate_tokens" => "yes" },
              },
            },
          },
        },
      )

    [missing_node, invalid_node].each do |node|
      runtime = build_runtime_for(node)

      assert_instance_of AgentCore::RuntimeSurface::Base, runtime.runtime_surface
      assert_instance_of AgentCore::RuntimeSurface::Runner, runtime.runtime_surface_runner
      assert_equal(
        {
          type: :noop,
          helpers: [],
          stage_limits: {},
        },
        runtime.execution_context_attributes.fetch(:runtime_surface),
      )
    end
  end

  test "selected agent runtime_surface config drives interactive runtime when no legacy agent_profile is stored" do
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    agent.update!(
      args: {
        "runtime_surface" => {
          "type" => "noop",
          "helpers" => { "estimate_tokens" => true, "estimate_messages" => true },
          "stage_limits" => {
            "prepare_turn" => { "timeout_s" => 0.5, "max_output_bytes" => 2048 },
          },
        },
        "runtime_surface_status" => "configured",
      },
    )

    node =
      build_pending_agent_node(
        metadata: {
          "routing" => { "channel" => "web" },
          "agent" => { "key" => "main" },
        },
        agent: agent,
        default_execution_target: nil,
      )

    runtime = build_runtime_for(node)

    assert_equal(
      {
        type: :noop,
        helpers: [:estimate_messages, :estimate_tokens],
        stage_limits: {
          prepare_turn: { timeout_s: 0.5, max_output_bytes: 2048 },
        },
      },
      runtime.execution_context_attributes.fetch(:runtime_surface),
    )
  end

  test "top-level manifest-driven runtime requires a materialized programmable run when no provider override is supplied" do
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")

    node =
      build_pending_agent_node(
        metadata: {
          "agent" => { "key" => "main" },
        },
      )

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }

    assert_equal "cybros.agent_runtime_resolver.programmable_run_required", error.code
  end

  test "runtime_for uses the stricter provider hard cap while preserving raw budget observability fields" do
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
            context_window_tokens: 12000
            models:
              mock-model:
                display_name: "Mock"
                api_model: "mock-model"
                context_window_tokens: 20000
                context_soft_limit_tokens: 9000
                context_soft_limit_ratio: 0.8
                capabilities: { protocol: "chat_completions", tools: { tool_calling: true } }
      YAML
    ) do
      node =
        build_pending_agent_node(
          metadata: {
            "agent" => { "agent_profile" => "coding" },
            "llm" => { "model_ref" => "dev/mock-model" },
          },
        )

      runtime = build_runtime_for(node)

      assert_equal 12000, runtime.context_window_tokens
      assert_equal 20000, runtime.model_context_window_tokens
      assert_equal 12000, runtime.provider_context_window_tokens
      assert_equal 9000, runtime.context_soft_limit_tokens
      assert_equal 0.8, runtime.context_soft_limit_ratio
    end
  end

  test "runtime_for registers compact_context canonically but only exposes it when budget policy advises compaction" do
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
            models:
              mock-model:
                display_name: "Mock"
                api_model: "mock-model"
                context_window_tokens: 20000
                capabilities: { protocol: "chat_completions", tools: { tool_calling: true } }
      YAML
    ) do
      node =
        build_pending_agent_node(
          metadata: {
            "agent" => { "agent_profile" => "coding" },
            "llm" => { "model_ref" => "dev/mock-model" },
          },
        )

      runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

      assert runtime.tools_registry.include?("compact_context")

      definitions = runtime.tools_registry.definitions
      normal_visible =
        runtime.tool_policy.filter(
          tools: definitions,
          context: AgentCore::ExecutionContext.new(attributes: { context_budget: { budget_action: "none" } }),
        )
      advise_visible =
        runtime.tool_policy.filter(
          tools: definitions,
          context: AgentCore::ExecutionContext.new(attributes: { context_budget: { budget_action: "advise_compact" } }),
        )
      enqueue_visible =
        runtime.tool_policy.filter(
          tools: definitions,
          context: AgentCore::ExecutionContext.new(attributes: { context_budget: { budget_action: "enqueue_compact" } }),
        )

      tool_name = lambda { |tool|
        tool[:name] || tool["name"] || tool.dig(:function, :name) || tool.dig("function", "name")
      }

      normal_names = normal_visible.map(&tool_name)
      advise_names = advise_visible.map(&tool_name)
      enqueue_names = enqueue_visible.map(&tool_name)

      refute_includes normal_names, "compact_context"
      assert_includes advise_names, "compact_context"
      refute_includes enqueue_names, "compact_context"
      assert_equal Cybros::ContextBudget::DefaultPolicy, runtime.context_budget_policy
    end
  end

  private

    def with_catalog_yaml(yaml)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "providers.test.yml")
        File.write(path, yaml)

        singleton = Cybros::LLM::Catalog.singleton_class
        singleton.alias_method :__agent_runtime_resolver_test_original_resolve_sources, :resolve_sources
        singleton.define_method(:resolve_sources) { [path] }

        begin
          Cybros::LLM::Catalog.reload!
          yield
        ensure
          singleton.alias_method :resolve_sources, :__agent_runtime_resolver_test_original_resolve_sources
          singleton.remove_method :__agent_runtime_resolver_test_original_resolve_sources
          Cybros::LLM::Catalog.reload!
        end
      end
    end

    def build_pending_agent_node(metadata:, agent: :__default__, agent_program: :__default__, default_execution_target: :__default__)
      conversation =
        create_conversation!(
          metadata: metadata,
          agent: agent,
          agent_program: agent_program,
          default_execution_target: default_execution_target,
        )
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

    def build_runtime_for(node)
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    end
end
