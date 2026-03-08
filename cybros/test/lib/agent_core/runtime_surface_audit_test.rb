require "test_helper"

class AgentCore::RuntimeSurfaceAuditTest < ActiveSupport::TestCase
  class ProjectingSurface < AgentCore::RuntimeSurface::Base
    def project_tool_result(input:)
      AgentCore::RuntimeSurface::Decisions::ToolResultProjection.new(
        action: :replace,
        projected_result: AgentCore::Resources::Tools::ToolResult.success(text: "safe summary").to_h,
        reason: "mask_raw_body",
        metadata: {},
      )
    end
  end

  class ExplodingFinalizeSurface < AgentCore::RuntimeSurface::Base
    def finalize_output(input:)
      raise "boom: #{input.draft_output.fetch("content")}"
    end
  end

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

  test "project_tool_result audit captures safe stage facts and merged outcome without raw body leakage" do
    instrumenter = AgentCore::Observability::TraceRecorder.new(capture: :full)
    runtime =
      runtime_with_tool_registry(
        instrumenter: instrumenter,
        runtime_surface: ProjectingSurface.new,
      ) do
        AgentCore::Resources::Tools::ToolResult.success(
          text: "api_key=super-secret\nraw body",
          metadata: { artifact_refs: [{ id: "artifact-1" }] },
        )
      end

    execute_task!(runtime: runtime, tool_name: "shell_exec")

    events = audit_events(instrumenter: instrumenter, stage: "project_tool_result")
    stage_event = events.find { |event| event.fetch("kind") == "stage" }
    outcome_event = events.find { |event| event.fetch("kind") == "outcome" }

    refute_nil stage_event
    refute_nil outcome_event
    assert_equal "tool_result_projection", stage_event.dig("decision", "type")
    assert_equal "replace", stage_event.dig("decision", "action")
    assert_equal 2, stage_event.dig("input_snapshot", "result_meta", "line_count")
    assert_equal 1, outcome_event.dig("merged_outcome", "raw_result_ref", "artifact_ref_count")
    assert_equal 1, outcome_event.dig("merged_outcome", "projected_result", "content_block_count")
    refute_includes events.to_json, "super-secret"
    refute_includes events.to_json, "raw body"
  end

  test "finalize_output audit records fallback and merged outcome without logging draft body" do
    instrumenter = AgentCore::Observability::TraceRecorder.new(capture: :full)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: StubProvider.new(message: AgentCore::Message.new(role: :assistant, content: "very sensitive draft answer")),
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        runtime_surface: ExplodingFinalizeSurface.new,
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
        llm_options: { stream: false },
        instrumenter: instrumenter,
      )

    execute_agent!(runtime: runtime)

    events = audit_events(instrumenter: instrumenter, stage: "finalize_output")
    stage_event = events.find { |event| event.fetch("kind") == "stage" }
    outcome_event = events.find { |event| event.fetch("kind") == "outcome" }

    refute_nil stage_event
    refute_nil outcome_event
    assert_equal true, stage_event.fetch("fallback")
    assert_equal "error", stage_event.fetch("failure_reason")
    assert_equal "pass", stage_event.dig("decision", "type")
    assert_equal false, outcome_event.dig("merged_outcome", "applied")
    refute_includes events.to_json, "very sensitive draft answer"
  end

  private

    def audit_events(instrumenter:, stage:)
      instrumenter.events.filter_map do |event|
        next unless event.fetch(:name) == "agent_core.runtime_surface.audit"

        payload = event.fetch(:payload)
        next unless payload.fetch("stage") == stage

        payload
      end
    end

    def execute_task!(runtime:, tool_name:)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      task =
        conversation.root_graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          lane_id: conversation.chat_lane.id,
          turn_id: turn.fetch(:agent_node).turn_id,
          metadata: {},
          body_input: {
            "name" => tool_name,
            "requested_name" => tool_name,
            "tool_call_id" => "tc_1",
            "arguments" => { "command" => "echo hi" },
            "arguments_summary" => "{\"command\":\"echo hi\"}",
          },
        )

      with_runtime(runtime) do
        AgentCore::DAG::Executors::TaskExecutor.new.execute(
          node: task,
          context: [{ "node_type" => Messages::UserMessage.node_type_key, "payload" => { "input" => { "content" => "hello" } } }],
          stream: nil,
        )
      end
    end

    def execute_agent!(runtime:)
      conversation = create_conversation!
      turn = conversation.append_user_message!(content: "Hello")
      agent = turn.fetch(:agent_node)

      with_runtime(runtime) do
        AgentCore::DAG::Executors::AgentMessageExecutor.new.execute(
          node: agent,
          context: conversation.dag_graph.context_for_full(agent.id),
          stream: nil,
        )
      end
    end

    def runtime_with_tool_registry(instrumenter:, runtime_surface:, &block)
      registry = AgentCore::Resources::Tools::Registry.new
      registry.register(
        AgentCore::Resources::Tools::Tool.new(
          name: "shell_exec",
          description: "shell_exec",
          parameters: {},
          &block
        )
      )

      AgentCore::DAG::Runtime.new(
        provider: Struct.new(:name).new("test-provider"),
        model: "dev/mock-model",
        tools_registry: registry,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: {},
        instrumenter: instrumenter,
        runtime_surface: runtime_surface,
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new,
      )
    end

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
