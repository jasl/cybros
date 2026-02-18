require "test_helper"

class DAG::GraphPolicyTest < ActiveSupport::TestCase
  test "validate_leaf_invariant! uses graph policy repair attributes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    leaf = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})

    policy = Class.new(DAG::GraphPolicy) do
      def initialize
        @default = DAG::GraphPolicies::Default.new
      end

      def body_class_for_node_type(node_type)
        return ::Messages::Summary if node_type.to_s == DAG::Node::TASK

        @default.body_class_for_node_type(node_type)
      end

      def leaf_valid?(node)
        node.pending? || node.running?
      end

      def leaf_repair_node_attributes(_leaf)
        {
          node_type: DAG::Node::TASK,
          state: DAG::Node::PENDING,
          metadata: { "generated_by" => "test_policy" },
        }
      end

      def leaf_repair_edge_attributes(_leaf, _repaired_node)
        {
          edge_type: DAG::Edge::SEQUENCE,
          metadata: { "generated_by" => "test_policy" },
        }
      end
    end.new

    graph.singleton_class.send(:define_method, :policy) { policy }

    begin
      created = graph.with_graph_lock! { graph.validate_leaf_invariant! }
      assert created

      repaired = graph.nodes.find_by!(metadata: { "generated_by" => "test_policy" })
      assert_equal DAG::Node::TASK, repaired.node_type
      assert_equal DAG::Node::PENDING, repaired.state
      assert_instance_of Messages::Summary, repaired.body

      assert graph.edges.exists?(
        from_node_id: leaf.id,
        to_node_id: repaired.id,
        edge_type: DAG::Edge::SEQUENCE,
        metadata: { "generated_by" => "test_policy" }
      )
    ensure
      graph.singleton_class.send(:remove_method, :policy)
    end
  end

  test "transcript_for uses graph policy transcript_include? decisions" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    task = graph.nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::FINISHED,
      body_output: { "result" => "ok" },
      metadata: {}
    )
    agent = graph.nodes.create!(
      node_type: DAG::Node::AGENT_MESSAGE,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE, metadata: {})
    graph.edges.create!(from_node_id: task.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE, metadata: {})

    transcript = graph.transcript_for(agent.id)
    assert_equal [DAG::Node::USER_MESSAGE, DAG::Node::AGENT_MESSAGE], transcript.map { |node| node["node_type"] }

    policy = Class.new(Messages::GraphPolicy) do
      def transcript_include?(context_node_hash)
        return true if context_node_hash["node_type"].to_s == DAG::Node::TASK

        super
      end
    end.new

    graph.singleton_class.send(:define_method, :policy) { policy }

    begin
      transcript = graph.transcript_for(agent.id)
      assert_equal [DAG::Node::USER_MESSAGE, DAG::Node::TASK, DAG::Node::AGENT_MESSAGE], transcript.map { |node| node["node_type"] }
    ensure
      graph.singleton_class.send(:remove_method, :policy)
    end
  end

  test "exclude_from_context! gating is controlled by graph policy" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})
    terminal = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    policy = Class.new(Messages::GraphPolicy) do
      def visibility_mutation_error(node:, graph:)
        _ = graph
        return "can only change visibility for terminal nodes" unless node.terminal?

        nil
      end
    end.new

    graph.singleton_class.send(:define_method, :policy) { policy }

    begin
      assert_nil terminal.context_excluded_at
      terminal.exclude_from_context!
      assert terminal.reload.context_excluded_at.present?
    ensure
      graph.singleton_class.send(:remove_method, :policy)
    end
  end

  test "scheduler uses policy claim_lease_seconds_for" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    parent = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::FINISHED, metadata: {})
    child = graph.nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
    graph.edges.create!(from_node_id: parent.id, to_node_id: child.id, edge_type: DAG::Edge::DEPENDENCY)

    policy = Class.new(Messages::GraphPolicy) do
      def claim_lease_seconds_for(node)
        _ = node
        5.seconds
      end
    end.new

    graph.singleton_class.send(:define_method, :policy) { policy }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [child.id], claimed.map(&:id)

      child.reload
      assert_equal 5, (child.lease_expires_at - child.claimed_at).to_i
    ensure
      graph.singleton_class.send(:remove_method, :policy)
    end
  end
end
