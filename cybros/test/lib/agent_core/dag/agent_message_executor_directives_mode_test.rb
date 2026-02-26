require "test_helper"

class AgentCoreDAGAgentMessageExecutorDirectivesModeTest < ActiveSupport::TestCase
  class FakeDirectivesProvider < AgentCore::Resources::Provider::Base
    def initialize(response_text:)
      @response_text = response_text.to_s
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = options

      raise "stream not supported" if stream

      msg = AgentCore::Message.new(role: :assistant, content: @response_text)
      AgentCore::Resources::Provider::Response.new(message: msg, stop_reason: :end_turn)
    end

    def name = "fake_directives"
  end

  test "directives_config enables directives runner and stores directives in payload" do
    envelope =
      JSON.generate(
        {
          "assistant_text" => "Hello",
          "directives" => [
            {
              "type" => "patch",
              "payload" => { "op" => "set", "path" => "/draft/title", "value" => "Hi" },
            },
          ],
        },
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: FakeDirectivesProvider.new(response_text: envelope),
        model: "gpt-4o-mini",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        directives_config: {},
        token_counter: AgentCore::Resources::TokenCounter::Heuristic.new,
      )

    prev_resolver = AgentCore::DAG.runtime_resolver
    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    conversation = Conversation.create!(metadata: { "agent" => { "agent_profile" => "subagent" } })
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "hi",
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

    context = graph.context_for_full(node.id, limit_turns: 50)
    result = AgentCore::DAG::Executors::AgentMessageExecutor.new.execute(node: node, context: context, stream: nil)

    assert_equal DAG::Node::FINISHED, result.state
    assert_equal "Hello", result.content
    assert_equal "Hello", result.payload.fetch("content")
    assert_equal(
      [{ "type" => "patch", "payload" => { "op" => "set", "path" => "/draft/title", "value" => "Hi" } }],
      result.payload.fetch("directives"),
    )
    assert_equal true, result.metadata.dig("directives", "enabled")
    assert_equal true, result.metadata.dig("directives", "ok")
  ensure
    AgentCore::DAG.runtime_resolver = prev_resolver
  end
end
