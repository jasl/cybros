# frozen_string_literal: true

require "test_helper"

class Cybros::AgentRuntimeResolverTest < ActiveSupport::TestCase
  test "agent_profile hash applies prompt and tool restrictions" do
    conversation =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => {
              "base" => "coding",
              "prompt_mode" => "minimal",
              "memory_search_limit" => 0,
              "tools_allowed" => ["memory_*"],
              "repo_docs_enabled" => false,
              "context_turns" => 12,
            },
          },
        },
      )

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

    runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    assert_equal :minimal, runtime.prompt_mode
    assert_equal 0, runtime.memory_search_limit
    assert_equal 12, runtime.context_turns
    assert_equal [], runtime.prompt_injection_sources

    ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

    denied = runtime.tool_policy.authorize(name: "subagent_spawn", arguments: {}, context: ctx)
    assert denied.denied?
    assert_equal "tool_not_in_profile", denied.reason

    allowed = runtime.tool_policy.authorize(name: "memory_search", arguments: {}, context: ctx)
    assert allowed.allowed?
  end

  test "rejects unknown agent_profile string" do
    conversation =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => "wat",
          },
        },
      )

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

    err =
      assert_raises(AgentCore::ValidationError) do
        Cybros::AgentRuntimeResolver.runtime_for(
          node: node,
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      end

    assert_equal "cybros.agent_runtime_resolver.agent_profile_must_be_one_of", err.code
  end

  test "rejects invalid context_turns metadata" do
    conversation =
      Conversation.create!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "context_turns" => "abc",
          },
        },
      )

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

    err =
      assert_raises(AgentCore::ValidationError) do
        Cybros::AgentRuntimeResolver.runtime_for(
          node: node,
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      end

    assert_equal "cybros.agent_runtime_resolver.context_turns_must_be_an_integer", err.code
  end
end
