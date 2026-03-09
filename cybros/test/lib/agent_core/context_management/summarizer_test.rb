require "test_helper"

class AgentCore::ContextManagement::SummarizerTest < Minitest::Test
  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(response_text:)
      @response_text = response_text
      @calls = []
    end

    attr_reader :calls

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }

      AgentCore::Resources::Provider::Response.new(
        message: AgentCore::Message.new(role: :assistant, content: @response_text),
        stop_reason: :end_turn,
      )
    end
  end

  def test_summarize_forwards_runtime_governance_to_provider
    provider = StubProvider.new(response_text: "updated summary")
    summarizer = AgentCore::ContextManagement::Summarizer.new(provider: provider, model: "summary-model")

    summary =
      summarizer.summarize(
        previous_summary: "before",
        transcript: "after",
        max_output_tokens: 128,
        runtime_governance: {
          provider_request_id: "turn-1:node-1:summary:attempt:1",
          request_namespace: "turn-1:node-1:summary",
        },
      )

    assert_equal "updated summary", summary
    assert_equal(
      "turn-1:node-1:summary:attempt:1",
      provider.calls.first.dig(:options, :runtime_governance, :provider_request_id),
    )
  end
end
