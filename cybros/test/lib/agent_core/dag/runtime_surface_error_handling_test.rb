require "test_helper"

class AgentCore::DAG::RuntimeSurfaceErrorHandlingTest < ActiveSupport::TestCase
  class ProviderFailure < AgentCore::Resources::Provider::Base
    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      raise AgentCore::ProviderError.new("provider leaked internal detail", status: 500, body: { "secret" => "123" })
    end
  end

  class SafeErrorSurface < AgentCore::RuntimeSurface::Base
    def handle_error(input:)
      AgentCore::RuntimeSurface::Decisions::ErrorHandling.new(
        action: :user_safe_message,
        output: {
          "content" => "Temporary upstream failure. Please retry.",
        },
        reason: "provider_masked",
        metadata: {
          "stage" => input.stage,
          "error_class" => input.error.fetch("class"),
        },
      )
    end
  end

  class ExplodingErrorSurface < AgentCore::RuntimeSurface::Base
    def handle_error(input:)
      raise "boom: #{input.error.fetch("class")}"
    end
  end

  class SuccessfulProvider < AgentCore::Resources::Provider::Base
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name = "successful_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      @calls += 1

      {
        message: AgentCore::Message.new(role: :assistant, content: "provider answer"),
        stop_reason: :end_turn,
        usage: {},
        streamed_output: false,
        used_model: model,
        metadata: {},
      }
    end
  end

  class MalformedProviderResponse < AgentCore::Resources::Provider::Base
    def name = "malformed_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      {
        message: AgentCore::Message.new(role: :assistant, content: "provider answer"),
        usage: {},
        streamed_output: false,
        used_model: model,
        metadata: {},
      }
    end
  end

  test "programmable after_task_notice can translate provider failures into a safe assistant message" do
    handled_notices = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |params, _base_result, _identity|
            handled_notices << params.fetch("task_notice")
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Recovering from runtime failure",
                  "state" => "running",
                },
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "programmable runtime fallback",
                  },
                },
              ],
            }
          end,
        },
      ).start

    result, run = execute_programmable_agent!(server:)
    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "after_task_notice")

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "programmable runtime fallback", result.content
    assert_equal "programmable runtime fallback", result.payload.fetch("content")
    assert_equal "programmable runtime fallback", result.payload.dig("message", "content")
    assert_equal "succeeded", invocation.status
    assert_equal "provider_error", handled_notices.dig(0, "notice", "kind")
  ensure
    server&.shutdown
  end

  test "programmable after_task_notice does not fall back to legacy handle_error when no message is emitted" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Handling runtime failure",
                  "state" => "running",
                },
              ],
            }
          end,
        },
      ).start

    result, _run = execute_programmable_agent!(server:, runtime_surface: SafeErrorSurface.new)

    assert_equal DAG::Node::ERRORED, result.state
    assert_includes result.error, "ProviderError"
    assert_nil result.payload
  ensure
    server&.shutdown
  end

  test "programmable after_task_notice can translate hard-cap failures into a safe assistant message" do
    handled_notices = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |params, _base_result, _identity|
            handled_notices << params.fetch("task_notice")
            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "context budget fallback",
                  },
                },
              ],
            }
          end,
        },
      ).start

    result, run =
      execute_programmable_agent!(
        server: server,
        runtime_overrides: {
          context_window_tokens: 1,
        },
      )
    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "after_task_notice")

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "context budget fallback", result.content
    assert_equal "succeeded", invocation.status
    assert_equal "hardcap_reached", handled_notices.dig(0, "notice", "kind")
    assert_equal "AgentCore::ContextWindowExceededError", handled_notices.dig(0, "error", "class")
    assert_equal false, handled_notices.dig(0, "user_decision_required")
  ensure
    server&.shutdown
  end

  test "programmable after_task_notice can append follow-up work without reviving the failed provider task" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "create_task",
                  "logical_tool_name" => "subagent_spawn",
                  "placement" => "append",
                  "input" => {
                    "name" => "Helper",
                    "prompt" => "Summarize this",
                  },
                },
              ],
            }
          end,
        },
      ).start

    routed_tool = nil
    result, run =
      execute_programmable_agent!(
        server: server,
        run_snapshot_builder: lambda do |program:, **|
          snapshot = build_capability_snapshot(program_id: program.id)
          routed_tool = snapshot.route_for!("subagent_spawn")
          tool_surface =
            Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
              capability_registry_snapshot: snapshot,
              selected_tool_ids: [routed_tool.effective_tool_id],
              tool_surface_label: "fixture-agent-priority",
            )

          {
            "capability_snapshot" => capability_snapshot_payload(snapshot),
            "draft" => {
              "planning" => {
                "tool_surface" => tool_surface_payload(tool_surface, snapshot: snapshot),
              },
            },
          }
        end,
      )
    agent_node = run.conversation.root_graph.nodes.find(run.dag_node_id)

    queued = run.conversation.turn_internal_tasks.where(turn_id: agent_node.turn_id).ordered.sole

    assert_equal DAG::Node::ERRORED, result.state
    assert_includes result.error, "ProviderError"
    assert_equal "subagent_spawn", queued.logical_tool_name
    assert_equal agent_node.id, queued.source_node_id
    assert_nil queued.materialized_task_node_id
    assert_equal routed_tool.effective_tool_id, queued.effective_tool_id
    assert_equal routed_tool.implementation_source, queued.implementation_source
    assert_equal routed_tool.implementation_ref, queued.implementation_ref

    TurnInternalTasks::Materializer.materialize_ready!(graph: run.conversation.root_graph)

    task = run.conversation.root_graph.nodes.find(queued.reload.materialized_task_node_id)
    assert_equal DAG::Node::PENDING, task.state
    assert_equal "subagent_spawn", task.body_input.fetch("requested_name")
    assert_equal routed_tool.effective_tool_id, task.body_input.fetch("effective_tool_id")
    assert run.conversation.root_graph.edges.exists?(
      from_node_id: run.dag_node_id,
      to_node_id: task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
  ensure
    server&.shutdown
  end

  test "programmable on_context_pressure can prepend compact_context and defer the current agent step before the model call" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => Agents::Protocol::REQUIRED_METHODS + %w[on_context_pressure],
        },
        rpc_overrides: {
          "on_context_pressure" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Compacting context",
                  "state" => "running",
                },
                {
                  "type" => "create_task",
                  "logical_tool_name" => "compact_context",
                  "placement" => "prepend",
                  "input" => {
                    "reason" => "soft_limit_reached",
                  },
                },
              ],
            }
          end,
        },
      ).start
    provider_delegate = SuccessfulProvider.new
    result, run =
      execute_programmable_agent!(
        server: server,
        provider_delegate: provider_delegate,
        deployment_supported_methods: Agents::Protocol::REQUIRED_METHODS + %w[on_context_pressure],
        runtime_overrides: {
          context_window_tokens: 10_000,
          context_soft_limit_tokens: 1,
          context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        },
        run_snapshot_builder: lambda do |program:, **|
          snapshot =
            Cybros::ProgrammableAgent::CapabilitySnapshot.build(
              kernel_registry_version: "kernel:v1",
              agent_key: program.config_namespace,
              agent_capabilities_version: "agent:v1",
              kernel_tools: [
                {
                  logical_tool_name: "compact_context",
                  implementation_ref: "kernel://compact_context",
                },
              ],
              agent_tools: [],
            )
          route = snapshot.route_for!("compact_context")
          tool_surface =
            Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
              capability_registry_snapshot: snapshot,
              selected_tool_ids: [route.effective_tool_id],
              tool_surface_label: "fixture-on-context-pressure",
            )

          {
            "capability_snapshot" => capability_snapshot_payload(snapshot),
            "draft" => {
              "planning" => {
                "tool_surface" => tool_surface_payload(tool_surface, snapshot: snapshot),
              },
            },
          }
        end,
      )
    agent_node = run.conversation.root_graph.nodes.find(run.dag_node_id)
    prepended_task =
      run.conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: agent_node.turn_id)
        .order(:id)
        .sole
    deferred_agent =
      run.conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: agent_node.turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .sole
    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "on_context_pressure")

    assert_equal DAG::Node::STOPPED, result.state
    assert_equal "Compacting context", agent_node.reload.body_output_preview.fetch("content")
    assert_equal 0, provider_delegate.calls
    assert_equal "succeeded", invocation.status
    assert_equal "compact_context", prepended_task.body_input.fetch("requested_name")
    assert_equal DAG::Node::PENDING, deferred_agent.state
  ensure
    server&.shutdown
  end

  test "programmable on_context_pressure can prepend memory_store before compact_context without creating a hidden loop" do
    travel_to Time.zone.local(2026, 3, 16, 9, 30, 0) do
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          identity_overrides: {
            "supported_methods" => Agents::Protocol::REQUIRED_METHODS + %w[on_context_pressure],
          },
          rpc_overrides: {
            "on_context_pressure" => lambda do |_params, _base_result, _identity|
              {
                "actions" => [
                  {
                    "type" => "set_step_status",
                    "text" => "Flushing memory before compaction",
                    "state" => "running",
                  },
                  {
                    "type" => "create_task",
                    "logical_tool_name" => "memory_store",
                    "placement" => "prepend",
                    "input" => {
                      "content" => "[auto-memory-flush] durable state",
                      "mode" => "append",
                      "scope" => "conversation",
                      "target" => "memory/2026-03-16.md",
                    },
                  },
                  {
                    "type" => "create_task",
                    "logical_tool_name" => "compact_context",
                    "placement" => "prepend",
                    "input" => {
                      "reason" => "soft_limit_reached",
                    },
                  },
                ],
              }
            end,
          },
        ).start
      provider_delegate = SuccessfulProvider.new
      result, run =
        execute_programmable_agent!(
          server: server,
          provider_delegate: provider_delegate,
          deployment_supported_methods: Agents::Protocol::REQUIRED_METHODS + %w[on_context_pressure],
          runtime_overrides: {
            context_window_tokens: 10_000,
            context_soft_limit_tokens: 1,
            context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
          },
          run_snapshot_builder: lambda do |program:, **|
            snapshot =
              Cybros::ProgrammableAgent::CapabilitySnapshot.build(
                kernel_registry_version: "kernel:v1",
                agent_key: program.config_namespace,
                agent_capabilities_version: "agent:v1",
                kernel_tools: [
                  {
                    logical_tool_name: "compact_context",
                    implementation_ref: "kernel://compact_context",
                  },
                ],
                agent_tools: [
                  {
                    logical_tool_name: "memory_store",
                    implementation_ref: "agent://memory_store",
                  },
                ],
              )
            tool_surface =
              Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
                capability_registry_snapshot: snapshot,
                selected_tool_ids: snapshot.effective_tools.map(&:effective_tool_id),
                tool_surface_label: "fixture-memory-flush-on-context-pressure",
              )

            {
              "capability_snapshot" => capability_snapshot_payload(snapshot),
              "draft" => {
                "planning" => {
                  "tool_surface" => tool_surface_payload(tool_surface, snapshot: snapshot),
                },
              },
            }
          end,
        )
      graph = run.conversation.root_graph
      agent_node = graph.nodes.find(run.dag_node_id)
      prepended_tasks =
        graph.nodes
          .where(node_type: Messages::Task.node_type_key, turn_id: agent_node.turn_id)
          .order(:id)
          .to_a
      deferred_agent =
        graph.nodes
          .where(node_type: Messages::AgentMessage.node_type_key, turn_id: agent_node.turn_id)
          .where.not(id: agent_node.id)
          .order(:id)
          .sole
      memory_arguments = prepended_tasks.first.body_input.fetch("arguments")

      assert_equal DAG::Node::STOPPED, result.state
      assert_equal "Flushing memory before compaction", agent_node.reload.body_output_preview.fetch("content")
      assert_equal 0, provider_delegate.calls
      assert_equal 2, prepended_tasks.size
      assert_equal %w[memory_store compact_context], prepended_tasks.map { |task| task.body_input.fetch("requested_name") }
      assert_equal "conversation", memory_arguments.fetch("scope")
      assert_equal "memory/2026-03-16.md", memory_arguments.fetch("target")
      refute memory_arguments.key?("root")
      assert_equal DAG::Node::PENDING, deferred_agent.state
      assert_empty graph.nodes.where(node_type: Messages::SystemMessage.node_type_key, turn_id: agent_node.turn_id)
      assert graph.edges.exists?(from_node_id: agent_node.id, to_node_id: prepended_tasks.first.id, edge_type: DAG::Edge::SEQUENCE)
      assert graph.edges.exists?(from_node_id: prepended_tasks.first.id, to_node_id: prepended_tasks.second.id, edge_type: DAG::Edge::SEQUENCE)
      assert graph.edges.exists?(from_node_id: prepended_tasks.second.id, to_node_id: deferred_agent.id, edge_type: DAG::Edge::SEQUENCE)
    ensure
      server&.shutdown
    end
  end

  test "programmable after_task_notice hook contract failures fail fast" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "not_a_real_action",
                },
              ],
            }
          end,
        },
      ).start

    error =
      assert_raises(AgentCore::ValidationError) do
        execute_programmable_agent!(server: server)
      end

    assert_equal "cybros.programmable_agent.hook_contract.invalid_action_type", error.code
  ensure
    server&.shutdown
  end

  test "programmable generic executor failures do not fall back to legacy handle_error" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start

    result, _run =
      execute_programmable_agent!(
        server: server,
        runtime_surface: SafeErrorSurface.new,
        provider_delegate: MalformedProviderResponse.new,
      )

    assert_equal DAG::Node::ERRORED, result.state
    assert_includes result.error, "NoMethodError"
    assert_nil result.payload
  ensure
    server&.shutdown
  end

  test "handle_error can translate provider failures into a safe assistant message" do
    result = execute_agent!(runtime_surface: SafeErrorSurface.new)

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "Temporary upstream failure. Please retry.", result.content
    assert_equal "Temporary upstream failure. Please retry.", result.payload.fetch("content")
    refute_includes result.payload.fetch("content"), "provider leaked internal detail"
  end

  test "handle_error failure safely falls back to the default errored result" do
    result = execute_agent!(runtime_surface: ExplodingErrorSurface.new)

    assert_equal DAG::Node::ERRORED, result.state
    assert_includes result.error, "ProviderError"
    assert_nil result.payload
  end

  private

    def execute_agent!(runtime_surface:)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      agent = turn.fetch(:agent_node)

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: ProviderFailure.new,
          model: "test-model",
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          runtime_surface: runtime_surface,
          runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
          llm_options: { stream: false },
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )

      executor = AgentCore::DAG::Executors::AgentMessageExecutor.new

      with_runtime(runtime) do
        executor.execute(
          node: agent,
          context: conversation.dag_graph.context_for_full(agent.id),
          stream: nil,
        )
      end
    end

    def execute_programmable_agent!(server:, runtime_surface: AgentCore::RuntimeSurface.default, run_snapshot_builder: nil, runtime_overrides: {}, provider_delegate: nil, deployment_supported_methods: nil)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      agent = turn.fetch(:agent_node)

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
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: deployment_supported_methods || Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent_runtime = create_agent_runtime!(program: program, execution_target: build_default_execution_profile!, deployment: deployment)
      conversation.update!(agent: agent_runtime, agent_config_schema_fingerprint: program.config_schema_fingerprint)
      recognized_deployment = recognize_agent_runtime!(agent: agent_runtime, deployment: deployment)
      snapshot =
        {
          "draft" => {
            "id" => SecureRandom.uuid,
            "planning" => { "step_plan" => { "summary" => "fixture summary" } },
          },
        }.deep_merge(run_snapshot_builder ? run_snapshot_builder.call(program: program, deployment: deployment, agent_node: agent) : {})
      run =
        create_conversation_run!(
          conversation: conversation,
          dag_node_id: agent.id,
          agent: agent_runtime,
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
          snapshot: snapshot,
        )

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: Cybros::ProgrammableAgentProvider.new(conversation_run: run, delegate: provider_delegate || ProviderFailure.new),
          model: "test-model",
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          runtime_surface: runtime_surface,
          runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
          llm_options: { stream: false },
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
          **runtime_overrides,
        )

      result =
        with_runtime(runtime) do
          AgentCore::DAG::Executors::AgentMessageExecutor.new.execute(
            node: agent,
            context: conversation.dag_graph.context_for_full(agent.id),
            stream: nil,
          )
        end

      [result, run]
    end

    def build_capability_snapshot(program_id:)
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_key: program_id,
        agent_capabilities_version: "agent:v1",
        kernel_tools: [
          {
            logical_tool_name: "compact_context",
            implementation_ref: "kernel://compact_context",
          },
          {
            logical_tool_name: "subagent_spawn",
            implementation_ref: "kernel://subagent_spawn",
          },
          {
            logical_tool_name: "subagent_run",
            implementation_ref: "kernel://subagent_run",
            execution_mode: "parallel_safe",
          },
        ],
        agent_tools: [
          {
            logical_tool_name: "subagent_spawn",
            implementation_ref: "agent://subagent_spawn",
          },
        ],
      )
    end

    def capability_snapshot_payload(snapshot)
      {
        "capability_registry_snapshot_id" => snapshot.snapshot_id,
        "kernel_capability_registry_version" => snapshot.kernel_registry_version,
        "agent_key" => snapshot.agent_key,
        "agent_capabilities_version" => snapshot.agent_capabilities_version,
        "effective_tools" => snapshot.effective_tools.map do |tool|
          {
            "logical_tool_name" => tool.logical_tool_name,
            "effective_tool_id" => tool.effective_tool_id,
            "implementation_source" => tool.implementation_source,
            "implementation_ref" => tool.implementation_ref,
          }
        end,
      }
    end

    def tool_surface_payload(tool_surface, snapshot:)
      {
        "capability_registry_snapshot_id" => snapshot.snapshot_id,
        "selected_tool_ids" => tool_surface.selected_tool_ids,
        "tool_surface_label" => tool_surface.tool_surface_label,
        "tool_surface_id" => tool_surface.tool_surface_id,
        "logical_tool_names" => tool_surface.selected_tools.map(&:logical_tool_name),
      }
    end

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
