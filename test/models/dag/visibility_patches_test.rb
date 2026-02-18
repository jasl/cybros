require "test_helper"

class DAG::VisibilityPatchesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "request_soft_delete! applies immediately when graph is idle and node is terminal" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal :applied, node.request_soft_delete!
    assert node.reload.deleted_at.present?
    assert_not DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?
  end

  test "request_exclude_from_context! defers when graph has running nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})
    node = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal :deferred, node.request_exclude_from_context!
    assert_nil node.reload.context_excluded_at

    patch = DAG::NodeVisibilityPatch.find_by!(graph_id: graph.id, node_id: node.id)
    assert patch.context_excluded_at.present?
    assert_nil patch.deleted_at
  end

  test "request_soft_delete! defers for non-terminal nodes and applies later when terminal and idle" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})

    assert_equal :deferred, node.request_soft_delete!
    assert_nil node.reload.deleted_at
    assert DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?

    node.update!(state: DAG::Node::FINISHED)

    applied = 0
    graph.with_graph_lock! do
      applied = graph.apply_visibility_patches_if_idle!
    end

    assert_equal 1, applied
    assert node.reload.deleted_at.present?
    assert_not DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?
  end

  test "patch merges exclude and delete requests and applies both" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    running = graph.nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::RUNNING, metadata: {})
    node = graph.nodes.create!(
      node_type: DAG::Node::USER_MESSAGE,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    excluded_at = Time.current
    deleted_at = excluded_at + 1.second

    assert_equal :deferred, node.request_exclude_from_context!(at: excluded_at)
    assert_equal :deferred, node.request_soft_delete!(at: deleted_at)

    patch = DAG::NodeVisibilityPatch.find_by!(graph_id: graph.id, node_id: node.id)
    assert_equal excluded_at.to_i, patch.context_excluded_at.to_i
    assert_equal deleted_at.to_i, patch.deleted_at.to_i

    running.update_columns(state: DAG::Node::FINISHED, updated_at: Time.current)

    graph.with_graph_lock! do
      assert_equal 1, graph.apply_visibility_patches_if_idle!
    end

    node.reload
    assert_equal excluded_at.to_i, node.context_excluded_at.to_i
    assert_equal deleted_at.to_i, node.deleted_at.to_i
    assert_not DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?
  end
end
