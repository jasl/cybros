require "test_helper"

class DAG::GraphAuditTest < ActiveSupport::TestCase
  test "scan detects and repair! compresses active edges pointing at inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    a = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    b = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    edge = graph.edges.create!(from_node_id: a.id, to_node_id: b.id, edge_type: DAG::Edge::SEQUENCE)

    b.update_columns(compressed_at: Time.current, compressed_by_id: a.id, updated_at: Time.current)

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["type"] == DAG::GraphAudit::ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_ACTIVE_EDGE_TO_INACTIVE_NODE])
    assert edge.reload.compressed_at.present?
  end

  test "repair! deletes visibility patches for inactive nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})
    patch = DAG::NodeVisibilityPatch.create!(graph: graph, node: node, context_excluded_at: Time.current)

    node.update_columns(compressed_at: Time.current, compressed_by_id: node.id, updated_at: Time.current)

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["subject_id"] == patch.id && i["type"] == DAG::GraphAudit::ISSUE_STALE_VISIBILITY_PATCH }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_STALE_VISIBILITY_PATCH])
    assert_not DAG::NodeVisibilityPatch.exists?(id: patch.id)
  end

  test "repair! fixes leaf invariant violations by calling validate_leaf_invariant!" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::FINISHED, metadata: {})

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["type"] == DAG::GraphAudit::ISSUE_LEAF_INVARIANT_VIOLATION }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_LEAF_INVARIANT_VIOLATION])
    assert graph.nodes.active.exists?(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
  end

  test "repair! reclaims stale running nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::RUNNING,
      lease_expires_at: 1.minute.ago,
      metadata: {}
    )

    issues = DAG::GraphAudit.scan(graph: graph)
    assert issues.any? { |i| i["subject_id"] == node.id && i["type"] == DAG::GraphAudit::ISSUE_STALE_RUNNING_NODE }

    DAG::GraphAudit.repair!(graph: graph, types: [DAG::GraphAudit::ISSUE_STALE_RUNNING_NODE])
    assert_equal DAG::Node::ERRORED, node.reload.state
    assert_equal "running_lease_expired", node.metadata.fetch("error")
  end

  test "scan reports misconfigured_graph when graph attachable is missing" do
    graph = DAG::Graph.create!

    issues = DAG::GraphAudit.scan(graph: graph)
    misconfigured = issues.find { |issue| issue["type"] == DAG::GraphAudit::ISSUE_MISCONFIGURED_GRAPH }
    assert misconfigured

    problem_codes = misconfigured.dig("details", "problems").map { |problem| problem["code"] }
    assert_includes problem_codes, "attachable_missing"
  end

  test "scan reports misconfigured_graph when default_leaf_repair is not unique" do
    Messages.const_set(
      :BadLeafRepair,
      Class.new(::DAG::NodeBody) do
        class << self
          def default_leaf_repair?
            true
          end

          def executable?
            true
          end

          def leaf_terminal?
            true
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph

    issues = DAG::GraphAudit.scan(graph: graph)
    misconfigured = issues.find { |issue| issue["type"] == DAG::GraphAudit::ISSUE_MISCONFIGURED_GRAPH }
    assert misconfigured

    problem_codes = misconfigured.dig("details", "problems").map { |problem| problem["code"] }
    assert_includes problem_codes, "default_leaf_repair_not_unique"
  ensure
    Messages.send(:remove_const, :BadLeafRepair) if Messages.const_defined?(:BadLeafRepair, false)
  end

  test "scan reports misconfigured_graph when node_type_key collides" do
    Messages.const_set(
      :CollisionOne,
      Class.new(::DAG::NodeBody) do
        class << self
          def node_type_key
            "collision"
          end
        end
      end
    )

    Messages.const_set(
      :CollisionTwo,
      Class.new(::DAG::NodeBody) do
        class << self
          def node_type_key
            "collision"
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph

    issues = DAG::GraphAudit.scan(graph: graph)
    misconfigured = issues.find { |issue| issue["type"] == DAG::GraphAudit::ISSUE_MISCONFIGURED_GRAPH }
    assert misconfigured

    problem_codes = misconfigured.dig("details", "problems").map { |problem| problem["code"] }
    assert_includes problem_codes, "node_type_key_collision"
  ensure
    Messages.send(:remove_const, :CollisionOne) if Messages.const_defined?(:CollisionOne, false)
    Messages.send(:remove_const, :CollisionTwo) if Messages.const_defined?(:CollisionTwo, false)
  end

  test "scan reports misconfigured_graph when created_content_destination is invalid" do
    Messages.const_set(
      :InvalidDestination,
      Class.new(::DAG::NodeBody) do
        class << self
          def created_content_destination
            [:bogus, "x"]
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph

    issues = DAG::GraphAudit.scan(graph: graph)
    misconfigured = issues.find { |issue| issue["type"] == DAG::GraphAudit::ISSUE_MISCONFIGURED_GRAPH }
    assert misconfigured

    problem_codes = misconfigured.dig("details", "problems").map { |problem| problem["code"] }
    assert_includes problem_codes, "invalid_created_content_destination"
  ensure
    Messages.send(:remove_const, :InvalidDestination) if Messages.const_defined?(:InvalidDestination, false)
  end

  test "scan reports misconfigured_graph when a NodeBody hook raises" do
    Messages.const_set(
      :HookRaises,
      Class.new(::DAG::NodeBody) do
        class << self
          def default_leaf_repair?
            raise "boom"
          end
        end
      end
    )

    conversation = Conversation.create!
    graph = conversation.dag_graph

    issues = DAG::GraphAudit.scan(graph: graph)
    misconfigured = issues.find { |issue| issue["type"] == DAG::GraphAudit::ISSUE_MISCONFIGURED_GRAPH }
    assert misconfigured

    problem_codes = misconfigured.dig("details", "problems").map { |problem| problem["code"] }
    assert_includes problem_codes, "node_body_hook_error"
  ensure
    Messages.send(:remove_const, :HookRaises) if Messages.const_defined?(:HookRaises, false)
  end
end
