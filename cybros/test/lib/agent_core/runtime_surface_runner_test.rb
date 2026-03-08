require "test_helper"

class AgentCore::RuntimeSurfaceRunnerTest < Minitest::Test
  class RecordingInstrumenter < AgentCore::Observability::Instrumenter
    attr_reader :events

    def initialize
      @events = []
    end

    def _publish(name, payload)
      @events << [name, payload]
    end
  end

  class InspectingSurface < AgentCore::RuntimeSurface::Base
    def prepare_turn(input:)
      AgentCore::RuntimeSurface::Decisions::TurnRewrite.new(
        prompt: {
          estimated_tokens: input.helpers.estimate_tokens("hello"),
        },
        metadata: {
          helper_responds_to_unknown: input.helpers.respond_to?(:dangerous),
        },
      )
    end
  end

  class TimeoutSurface < AgentCore::RuntimeSurface::Base
    def prepare_turn(input:)
      _ = input
      sleep 0.05
      AgentCore::RuntimeSurface::Decisions::TurnRewrite.new(prompt: { ok: true }, metadata: {})
    end
  end

  class OversizedSurface < AgentCore::RuntimeSurface::Base
    def finalize_output(input:)
      AgentCore::RuntimeSurface::Decisions::FinalOutput.new(
        output: { "text" => "x" * 200 },
        metadata: { "source" => input.draft_output },
      )
    end
  end

  class ExplodingSurface < AgentCore::RuntimeSurface::Base
    def review_tool_call(input:)
      raise "boom: #{input.tool_call.fetch(:name)}"
    end
  end

  def test_runner_uses_common_stage_entrypoint_and_constrained_helpers
    instrumenter = RecordingInstrumenter.new
    runner = AgentCore::RuntimeSurface::Runner.new(helpers: { estimate_tokens: ->(text) { text.to_s.length } })

    result =
      runner.run(
        surface: InspectingSurface.new,
        stage: :prepare_turn,
        input: prepare_turn_input,
        execution_context: AgentCore::ExecutionContext.new(instrumenter: instrumenter),
      )

    refute result.fallback?
    assert_instance_of AgentCore::RuntimeSurface::Decisions::TurnRewrite, result.decision
    assert_equal 5, result.decision.prompt.fetch(:estimated_tokens)
    assert_equal false, result.decision.metadata.fetch(:helper_responds_to_unknown)
    assert_equal ["agent_core.runtime_surface.audit", "agent_core.runtime_surface.stage"], instrumenter.events.map(&:first).uniq.sort
    stage_event = instrumenter.events.find { |name, payload| name == "agent_core.runtime_surface.stage" && payload.fetch(:stage) == "prepare_turn" }
    audit_event = instrumenter.events.find { |name, payload| name == "agent_core.runtime_surface.audit" && payload.fetch("stage") == "prepare_turn" }
    refute_nil stage_event
    refute_nil audit_event
  end

  def test_runner_falls_back_when_stage_times_out
    runner =
      AgentCore::RuntimeSurface::Runner.new(
        stage_limits: {
          prepare_turn: { timeout_s: 0.001 },
        },
      )

    result =
      runner.run(
        surface: TimeoutSurface.new,
        stage: :prepare_turn,
        input: prepare_turn_input,
        execution_context: AgentCore::ExecutionContext.new,
      )

    assert result.fallback?
    assert_equal :timeout, result.failure_reason
    assert_instance_of AgentCore::RuntimeSurface::Decisions::Pass, result.decision
  end

  def test_runner_falls_back_when_decision_exceeds_size_limit
    runner =
      AgentCore::RuntimeSurface::Runner.new(
        stage_limits: {
          finalize_output: { max_output_bytes: 64 },
        },
      )

    result =
      runner.run(
        surface: OversizedSurface.new,
        stage: :finalize_output,
        input: finalize_output_input,
        execution_context: AgentCore::ExecutionContext.new,
      )

    assert result.fallback?
    assert_equal :output_limit_exceeded, result.failure_reason
    assert_instance_of AgentCore::RuntimeSurface::Decisions::Pass, result.decision
  end

  def test_runner_falls_back_when_surface_raises
    runner = AgentCore::RuntimeSurface::Runner.new

    result =
      runner.run(
        surface: ExplodingSurface.new,
        stage: :review_tool_call,
        input: review_tool_call_input,
        execution_context: AgentCore::ExecutionContext.new,
      )

    assert result.fallback?
    assert_equal :error, result.failure_reason
    assert_equal "RuntimeError", result.error_class
    assert_instance_of AgentCore::RuntimeSurface::Decisions::Pass, result.decision
  end

  private

    def prepare_turn_input
      AgentCore::RuntimeSurface::Inputs::PrepareTurn.new(
        prompt: { sections: [] },
        context: [],
        budget: {},
        capabilities: {},
        helpers: { ignored: true },
      )
    end

    def finalize_output_input
      AgentCore::RuntimeSurface::Inputs::FinalizeOutput.new(
        draft_output: { content: "draft" },
        context: [],
        budget: {},
        helpers: {},
      )
    end

    def review_tool_call_input
      AgentCore::RuntimeSurface::Inputs::ReviewToolCall.new(
        tool_call: { name: "shell_exec", arguments: { command: "pwd" } },
        context: [],
        capabilities: {},
        risk_hints: {},
        helpers: {},
      )
    end
end
