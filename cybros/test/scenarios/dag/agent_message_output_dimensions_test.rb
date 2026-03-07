require "test_helper"

class DAG::AgentMessageOutputDimensionsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class StubProvider < AgentCore::Resources::Provider::Base
    def name = "stub"

    def chat(messages:, model:, tools: nil, stream: false, **options)
      _ = messages
      _ = model
      _ = tools
      _ = stream
      _ = options

      AgentCore::Resources::Provider::Response.new(
        message: AgentCore::Message.new(role: :assistant, content: "Hi!"),
        stop_reason: :end_turn,
        usage: AgentCore::Resources::Provider::Usage.new(input_tokens: 1, output_tokens: 2, cache_creation_tokens: 0, cache_read_tokens: 0),
      )
    end
  end

  test "agent output includes provider_key/model_ref/api_model" do
    clear_enqueued_jobs
    clear_performed_jobs

    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    user = nil
    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    inner = StubProvider.new
    provider =
      Cybros::LLM::CapabilityGatedProvider.new(
        delegate: inner,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
        api_model: "gpt-5.4",
        supports_tools: true,
        supports_images: true,
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "gpt-5.4",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)

    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(agent.id)

      agent.reload
      assert_equal DAG::Node::FINISHED, agent.state
      assert_equal "openai", agent.body_output.fetch("provider_key")
      assert_equal "openai/gpt-5.4", agent.body_output.fetch("model_ref")
      assert_equal "gpt-5.4", agent.body_output.fetch("api_model")
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end
end
