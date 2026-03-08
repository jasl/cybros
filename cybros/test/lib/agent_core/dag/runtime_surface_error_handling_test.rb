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

    def with_runtime(runtime)
      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      yield
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end
end
