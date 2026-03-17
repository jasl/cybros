require "test_helper"

class AgentCore::DAG::AgentOutputFinalizationTest < ActiveSupport::TestCase
  PROGRAMMABLE_SUPPORTED_METHODS = Agents::Protocol::REQUIRED_METHODS + %w[before_finalize_output after_task_notice]

  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(message:)
      @message = message
    end

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      AgentCore::Resources::Provider::Response.new(
        message: @message,
        stop_reason: :end_turn,
      )
    end
  end

  class FinalizingSurface < AgentCore::RuntimeSurface::Base
    def finalize_output(input:)
      AgentCore::RuntimeSurface::Decisions::FinalOutput.new(
        output: {
          "content" => "finalized answer",
        },
        metadata: {
          "stage" => "finalized",
          "draft_content" => input.draft_output.fetch("content"),
        },
      )
    end
  end

  class ExplodingFinalizeSurface < AgentCore::RuntimeSurface::Base
    def finalize_output(input:)
      raise "boom: #{input.draft_output.fetch("content")}"
    end
  end

  test "programmable before_finalize_output can replace the final assistant output via emit_message" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => PROGRAMMABLE_SUPPORTED_METHODS,
        },
        rpc_overrides: {
          "before_finalize_output" => lambda do |params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Finalizing programmable output",
                  "state" => "running",
                },
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "programmable finalized answer",
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
        provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
      )

    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "programmable finalized answer", result.content
    assert_equal "programmable finalized answer", result.payload.fetch("content")
    assert_equal "programmable finalized answer", result.payload.dig("message", "content")
    assert_equal "succeeded", invocation.status
  ensure
    server&.shutdown
  end

  test "programmable before_finalize_output does not fall back to legacy finalize_output when no message is emitted" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => PROGRAMMABLE_SUPPORTED_METHODS,
        },
        rpc_overrides: {
          "before_finalize_output" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Inspecting final output",
                  "state" => "running",
                },
              ],
            }
          end,
        },
      ).start

    result, _run =
      execute_programmable_agent!(
        server: server,
        provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
        runtime_surface: FinalizingSurface.new,
      )

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "draft answer", result.content
    assert_equal "draft answer", result.payload.fetch("content")
  ensure
    server&.shutdown
  end

  test "programmable before_finalize_output can finish silently without leaking the draft output" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => PROGRAMMABLE_SUPPORTED_METHODS,
        },
        rpc_overrides: {
          "before_finalize_output" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Running silent housekeeping",
                  "state" => "running",
                },
                {
                  "type" => "finish_silently",
                  "reason" => "silent_housekeeping",
                },
              ],
            }
          end,
        },
      ).start

    result, run =
      execute_programmable_agent!(
        server: server,
        provider_message: AgentCore::Message.new(role: :assistant, content: "NO_REPLY"),
      )
    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")
    agent_node = run.conversation.root_graph.nodes.find(run.dag_node_id)
    output_preview = DAG::NodeBody.where(id: agent_node.body_id).pick(:output_preview)

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "", result.content
    assert_equal "", result.payload.fetch("content")
    assert_equal true, result.payload.fetch("silent_finalization")
    refute output_preview.fetch("content", "").present?
    assert_equal "succeeded", invocation.status
  ensure
    server&.shutdown
  end

  test "programmable before_finalize_output halt stops the current agent step" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => PROGRAMMABLE_SUPPORTED_METHODS,
        },
        rpc_overrides: {
          "before_finalize_output" => lambda do |_params, _base_result, _identity|
            {
              "actions" => [
                {
                  "type" => "halt",
                  "reason" => "agent_declined_turn",
                  "message" => "Agent declined to continue",
                },
              ],
            }
          end,
        },
      ).start

    result, run =
      execute_programmable_agent!(
        server: server,
        provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
      )

    agent = run.conversation.root_graph.nodes.find(run.dag_node_id)

    assert_equal DAG::Node::STOPPED, result.state
    assert_equal "agent_declined_turn", result.reason
    assert_equal DAG::Node::PENDING, agent.reload.state
  ensure
    server&.shutdown
  end

  test "programmable before_finalize_output hook contract failures fail fast instead of falling back" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: {
          "supported_methods" => PROGRAMMABLE_SUPPORTED_METHODS,
        },
        rpc_overrides: {
          "before_finalize_output" => lambda do |_params, _base_result, _identity|
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
        execute_programmable_agent!(
          server: server,
          provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
        )
      end

    assert_equal "cybros.programmable_agent.hook_contract.invalid_action_type", error.code
  ensure
    server&.shutdown
  end

  test "finalize_output rewrites the successful assistant output" do
    result =
      execute_agent!(
        provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
        runtime_surface: FinalizingSurface.new,
      )

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "finalized answer", result.content
    assert_equal "finalized answer", result.payload.fetch("content")
    assert_equal "finalized answer", result.payload.dig("message", "content")
  end

  test "finalize_output failure safely falls back to the original draft output" do
    result =
      execute_agent!(
        provider_message: AgentCore::Message.new(role: :assistant, content: "draft answer"),
        runtime_surface: ExplodingFinalizeSurface.new,
      )

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "draft answer", result.content
    assert_equal "draft answer", result.payload.fetch("content")
  end

  class ProgrammableStubProvider < StubProvider
    attr_reader :delegate_calls

    def initialize(message:)
      super
      @delegate_calls = []
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @delegate_calls << {
        messages: messages,
        model: model,
        tools: tools,
        stream: stream,
        options: options,
      }
      super
    end
  end

  private

    def execute_agent!(provider_message:, runtime_surface:)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      agent = turn.fetch(:agent_node)

      runtime =
        AgentCore::DAG::Runtime.new(
          provider: StubProvider.new(message: provider_message),
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

    def execute_programmable_agent!(server:, provider_message:, runtime_surface: AgentCore::RuntimeSurface.default)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      agent = turn.fetch(:agent_node)

      program =
        create_agent_record!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: PROGRAMMABLE_SUPPORTED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent_runtime = create_agent_runtime!(agent: program, execution_profile: build_default_execution_profile!, deployment: deployment)
      conversation.update!(agent: agent_runtime, agent_config_schema_fingerprint: program.config_schema_fingerprint)
      recognized_deployment = recognize_agent_runtime!(agent: agent_runtime, deployment: deployment)
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
          snapshot: {
            "draft" => {
              "id" => SecureRandom.uuid,
              "planning" => { "step_plan" => { "summary" => "fixture summary" } },
            },
          },
        )

      delegate_provider = ProgrammableStubProvider.new(message: provider_message)
      runtime =
        AgentCore::DAG::Runtime.new(
          provider: Cybros::ProgrammableAgentProvider.new(conversation_run: run, delegate: delegate_provider),
          model: "test-model",
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          runtime_surface: runtime_surface,
          runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
          llm_options: { stream: false },
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
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

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
