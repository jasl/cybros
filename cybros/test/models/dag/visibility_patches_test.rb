require "test_helper"

class DAG::VisibilityPatchesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "request_soft_delete! applies immediately when graph is idle and node is terminal" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal :applied, node.request_soft_delete!
    assert node.reload.deleted_at.present?
    assert_not DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?

    event = conversation.events.find_by!(event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGED, subject: node)
    assert_equal "request_applied", event.particulars.fetch("source")
    assert_equal "soft_delete", event.particulars.fetch("action")
  end

  test "request_exclude_from_context! defers when graph has running nodes" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    node = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal :deferred, node.request_exclude_from_context!
    assert_nil node.reload.context_excluded_at

    patch = DAG::NodeVisibilityPatch.find_by!(graph_id: graph.id, node_id: node.id)
    assert patch.context_excluded_at.present?
    assert_nil patch.deleted_at

    event =
      conversation.events.find_by!(
        event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGE_REQUESTED,
        subject: node
      )
    assert_equal "exclude_from_context", event.particulars.fetch("action")
    assert event.particulars.dig("desired", "context_excluded_at").present?
    assert_nil event.particulars.dig("desired", "deleted_at")
    assert_match(/running nodes/, event.particulars.fetch("reason"))
  end

  test "request_soft_delete! defers for non-terminal nodes and applies later when terminal and idle" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})

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

    event =
      conversation.events.find_by!(
        event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGED,
        subject: node
      )
    assert_equal "defer_apply", event.particulars.fetch("source")
    assert_equal "apply_visibility_patch", event.particulars.fetch("action")
  end

  test "patch merges exclude and delete requests and applies both" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    node = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
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

  test "apply_visibility_patches_if_idle! drops patches targeting inactive nodes" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    running = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::RUNNING, metadata: {})
    node = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal :deferred, node.request_soft_delete!
    assert DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?

    node.update_columns(compressed_at: Time.current, compressed_by_id: node.id, updated_at: Time.current)
    running.update_columns(state: DAG::Node::FINISHED, updated_at: Time.current)

    graph.with_graph_lock! do
      assert_equal 0, graph.apply_visibility_patches_if_idle!
    end

    assert_not DAG::NodeVisibilityPatch.where(graph_id: graph.id, node_id: node.id).exists?
    assert conversation.events.exists?(
      event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_PATCH_DROPPED,
      subject_type: "DAG::Node",
      subject_id: node.id
    )
  end
end
