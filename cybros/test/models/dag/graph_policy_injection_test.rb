require "test_helper"

class DAG::GraphPolicyInjectionTest < ActiveSupport::TestCase
  class FixedExecutor
    def initialize(payload)
      @payload = payload
    end

    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(payload: @payload, usage: { "total_tokens" => 1 })
    end
  end

  test "conversation-injected policy can block fork_from! on non-forkable node types" do
    user = create_user!
    conversation =
      Conversation.create!(
        user: user,
        title: "Chat",
        metadata: { "agent" => { "agent_profile" => "coding" }, "dag_graph_policy" => "product" }
      )

    graph = conversation.dag_graph

    from = nil
    graph.mutate! do |m|
      from =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    assert_raises(DAG::OperationNotAllowedError) do
      graph.mutate! do |m|
        m.fork_from!(from_node: from, node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "hi")
      end
    end
  end

  test "conversation-injected policy can block soft delete on non-deletable node types" do
    user = create_user!
    conversation =
      Conversation.create!(
        user: user,
        title: "Chat",
        metadata: { "agent" => { "agent_profile" => "coding" }, "dag_graph_policy" => "product" }
      )

    graph = conversation.dag_graph
    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    assert_raises(DAG::OperationNotAllowedError) do
      node.soft_delete!
    end
  end

  test "policy does not block leaf invariant repair (engine automation)" do
    user = create_user!
    conversation =
      Conversation.create!(
        user: user,
        title: "Chat",
        metadata: { "agent" => { "agent_profile" => "coding" }, "dag_graph_policy" => "product" }
      )

    graph = conversation.dag_graph

    graph.mutate! do |m|
      m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "hi", metadata: {})
    end

    leaf = graph.leaf_nodes.order(:id).last
    assert_equal Messages::AgentMessage.node_type_key, leaf.node_type
    assert_equal DAG::Node::PENDING, leaf.state
  end

  test "policy does not block runner state transitions (pending -> running -> finished)" do
    user = create_user!
    conversation =
      Conversation.create!(
        user: user,
        title: "Chat",
        metadata: { "agent" => { "agent_profile" => "coding" }, "dag_graph_policy" => "product" }
      )

    graph = conversation.dag_graph

    agent = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedExecutor.new({ "content" => "ok" }))

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      DAG::Runner.run_node!(agent.id)
    ensure
      DAG.executor_registry = original_registry
    end

    assert_equal DAG::Node::FINISHED, agent.reload.state
  end
end

