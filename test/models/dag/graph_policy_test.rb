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
end
