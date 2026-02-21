# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Provider::ProviderFailoverTest < Minitest::Test
  class StubProvider < AgentCore::Resources::Provider::Base
    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    attr_reader :calls

    def name = "stub_provider"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << { messages: messages, model: model, tools: tools, stream: stream, options: options }
      @handler.call(messages: messages, model: model, tools: tools, stream: stream, options: options)
    end
  end

  class CaptureInstrumenter < AgentCore::Observability::Instrumenter
    attr_reader :events

    def initialize
      @events = []
    end

    def _publish(name, payload)
      @events << { name: name, payload: payload }
    end
  end

  def test_failover_on_400_tools_keyword_uses_fallback_model
    provider =
      StubProvider.new do |model:, **_|
        case model
        when "primary"
          raise AgentCore::ProviderError.new("tools not supported", status: 400, body: { "error" => "tools not supported" })
        when "fallback"
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "ok"),
            stop_reason: :end_turn,
          )
        else
          raise "unexpected model=#{model.inspect}"
        end
      end

    inst = CaptureInstrumenter.new

    result =
      AgentCore::Resources::Provider::ProviderFailover.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: ["fallback"],
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        tools: [],
        stream: false,
        options: {},
        instrumenter: inst,
        run_id: "rid",
      )

    assert_equal "fallback", result.fetch(:used_model)
    attempts = result.fetch(:attempts)
    assert_equal 2, attempts.length
    assert_equal false, attempts.fetch(0).fetch("ok")
    assert_equal 400, attempts.fetch(0).fetch("status")
    assert_equal true, attempts.fetch(1).fetch("ok")

    assert_equal ["primary", "fallback"], provider.calls.map { |c| c.fetch(:model) }

    failover_events = inst.events.select { |e| e.fetch(:name) == "agent_core.llm.failover" }
    assert_equal 1, failover_events.length
    payload = failover_events.first.fetch(:payload)
    assert_equal "primary", payload.fetch(:requested_model)
    assert_equal "fallback", payload.fetch(:used_model)
    assert_equal 2, payload.fetch(:attempts).length
  end

  def test_does_not_failover_on_401
    provider =
      StubProvider.new do |model:, **_|
        raise AgentCore::ProviderError.new("unauthorized", status: 401) if model == "primary"
        raise "should not be called"
      end

    err =
      assert_raises(AgentCore::ProviderError) do
        AgentCore::Resources::Provider::ProviderFailover.call(
          provider: provider,
          requested_model: "primary",
          fallback_models: ["fallback"],
          messages: [AgentCore::Message.new(role: :user, content: "hi")],
          tools: [],
          stream: false,
          options: {},
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
          run_id: "rid",
        )
      end

    assert_equal 401, err.status
    assert_equal ["primary"], provider.calls.map { |c| c.fetch(:model) }
  end

  def test_failover_on_404_model_not_found
    provider =
      StubProvider.new do |model:, **_|
        case model
        when "primary"
          raise AgentCore::ProviderError.new("model not found", status: 404)
        when "fallback"
          AgentCore::Resources::Provider::Response.new(
            message: AgentCore::Message.new(role: :assistant, content: "ok"),
            stop_reason: :end_turn,
          )
        else
          raise "unexpected model=#{model.inspect}"
        end
      end

    result =
      AgentCore::Resources::Provider::ProviderFailover.call(
        provider: provider,
        requested_model: "primary",
        fallback_models: ["fallback"],
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        tools: [],
        stream: false,
        options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        run_id: "rid",
      )

    assert_equal "fallback", result.fetch(:used_model)
    assert_equal ["primary", "fallback"], provider.calls.map { |c| c.fetch(:model) }
  end
end
