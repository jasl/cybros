require "test_helper"

class AgentCore::RuntimeSurfaceContractTest < Minitest::Test
  class ValidSurface
    def prepare_turn(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
    def compact_context(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
    def review_tool_call(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
    def project_tool_result(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
    def finalize_output(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
    def handle_error(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
  end

  class InvalidSurface
    def prepare_turn(input:) = AgentCore::RuntimeSurface::Decisions::Pass.new
  end

  def test_base_returns_typed_pass_decisions_for_all_lifecycle_methods
    surface = AgentCore::RuntimeSurface::Base.new

    decisions = [
      surface.prepare_turn(input: AgentCore::RuntimeSurface::Inputs::PrepareTurn.new(prompt: {}, context: [], budget: {}, capabilities: {}, helpers: {})),
      surface.compact_context(input: AgentCore::RuntimeSurface::Inputs::CompactContext.new(context_window: [], budget: {}, capabilities: {}, helpers: {})),
      surface.review_tool_call(input: AgentCore::RuntimeSurface::Inputs::ReviewToolCall.new(tool_call: {}, context: [], capabilities: {}, risk_hints: {}, helpers: {})),
      surface.project_tool_result(input: AgentCore::RuntimeSurface::Inputs::ProjectToolResult.new(tool_call: {}, result_meta: {}, preview: {}, artifact_refs: [], context: [], budget: {}, helpers: {})),
      surface.finalize_output(input: AgentCore::RuntimeSurface::Inputs::FinalizeOutput.new(draft_output: {}, context: [], budget: {}, helpers: {})),
      surface.handle_error(input: AgentCore::RuntimeSurface::Inputs::HandleError.new(error: StandardError.new("boom"), stage: :prepare_turn, context: [], budget: {}, helpers: {})),
    ]

    assert_equal 6, decisions.length
    decisions.each do |decision|
      assert_instance_of AgentCore::RuntimeSurface::Decisions::Pass, decision
      refute_equal true, decision
      refute_equal false, decision
    end
  end

  def test_runtime_accepts_explicit_runtime_surface
    surface = ValidSurface.new

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        model: "gpt-5.4",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        runtime_surface: surface,
      )

    assert_same surface, runtime.runtime_surface
  end

  def test_runtime_rejects_invalid_runtime_surface
    error =
      assert_raises(AgentCore::ValidationError) do
        AgentCore::DAG::Runtime.new(
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          model: "gpt-5.4",
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          runtime_surface: InvalidSurface.new,
        )
      end

    assert_equal "agent_core.runtime_surface.surface_must_respond_to_lifecycle_method", error.code
    assert_equal "compact_context", error.details[:method]
  end
end
