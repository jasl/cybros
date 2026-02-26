require "test_helper"

class Cybros::AgentRuntimeResolverLlmProviderTest < ActiveSupport::TestCase
  def with_env(values)
    prior = {}
    values.each do |key, value|
      prior[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    prior.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def build_pending_agent_node(conversation:)
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    node = nil
    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
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

    node
  end

  test "runtime_for selects highest priority matching LLMProvider and model from agent.yml model.prefer" do
    LLMProvider.delete_all

    LLMProvider.create!(name: "p1", base_url: "http://p1.test/v1", api_key: "k1", model_allowlist: ["m1"], priority: 1, api_format: "openai")
    LLMProvider.create!(name: "p2", base_url: "http://p2.test/v1", api_key: "k2", model_allowlist: ["m1"], priority: 5, api_format: "openai")

    conversation =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "agent_program" => { "model_prefer" => ["m1"] },
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

    provider = runtime.provider
    assert_equal "simple_inference", provider.name
    assert_equal "m1", runtime.model

    # Implementation detail, but needed to prove DB-driven selection without making a network call.
    client_options = provider.instance_variable_get(:@client_options)
    assert_equal "http://p2.test/v1", client_options.fetch(:base_url)
  end

  test "runtime_for falls back to a model allowed by the chosen provider when no provider matches preferred/default" do
    LLMProvider.delete_all

    LLMProvider.create!(
      name: "p1",
      base_url: "http://p1.test/v1",
      api_key: "k1",
      model_allowlist: ["m2"],
      priority: 5,
      api_format: "openai",
    )

    conversation =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "agent_program" => { "model_prefer" => ["m1"] },
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    with_env("AGENT_CORE_MODEL" => "m1") do
      runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
      assert_equal "m2", runtime.model
    end
  end
end
