require "test_helper"

class AgentCore::DAG::AgentOutputFinalizationTest < ActiveSupport::TestCase
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

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
