require "test_helper"

class DAG::SteerCurrentTurnFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "steer_current_turn replaces the current user input within the same turn and archives the superseded block" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph

    original = conversation.append_user_message!(content: "draft request")
    original_user = original.fetch(:user_node)
    original_agent = original.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [original_agent.id], claimed.map(&:id)
    original_agent.body.merge_output!("content" => "partial answer")
    original_agent.body.save!

    result = conversation.steer_current_turn!(content: "revised request")

    steered_user = result.fetch(:user_node)
    steered_agent = result.fetch(:agent_node)

    assert_equal original_user.turn_id, steered_user.turn_id
    assert_equal original_user.turn_id, steered_agent.turn_id
    assert_equal DAG::Node::STOPPED, original_agent.reload.state
    assert original_user.reload.compressed_at.present?
    assert original_agent.reload.compressed_at.present?

    versions = original_user.versions(include_inactive: true).pluck(:id)
    assert_includes versions, original_user.id
    assert_includes versions, steered_user.id

    page_node_ids = conversation.message_page(limit: 20, mode: :full).fetch("messages").map { |message| message.fetch("node_id") }
    refute_includes page_node_ids, original_user.id
    refute_includes page_node_ids, original_agent.id
    assert_includes page_node_ids, steered_user.id
    assert_includes page_node_ids, steered_agent.id

    context_ids = conversation.context_for(steered_agent.id, mode: :full).map { |node| node.fetch("node_id") }
    refute_includes context_ids, original_user.id
    refute_includes context_ids, original_agent.id
    assert_includes context_ids, steered_user.id
    assert_includes context_ids, steered_agent.id
  end

  test "steer_current_turn can keep the superseded block in future context via action override while hiding old versions from transcript" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph

    original = conversation.append_user_message!(content: "draft request")
    original_user = original.fetch(:user_node)
    original_agent = original.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [original_agent.id], claimed.map(&:id)
    original_agent.body.merge_output!("content" => "partial answer")
    original_agent.body.save!

    result =
      conversation.steer_current_turn!(
        content: "revised request",
        interrupted_output_policy_override: "keep_context",
      )

    steered_agent = result.fetch(:agent_node)
    preserved_context =
      graph.nodes.active
        .where(turn_id: steered_agent.turn_id, node_type: Messages::SystemMessage.node_type_key)
        .order(:id)
        .last

    assert_equal "steer_current_turn", preserved_context.metadata["generated_by"]

    page_node_ids = conversation.message_page(limit: 20, mode: :full).fetch("messages").map { |message| message.fetch("node_id") }
    refute_includes page_node_ids, original_user.id
    refute_includes page_node_ids, original_agent.id

    context_ids = conversation.context_for(steered_agent.id, mode: :full).map { |node| node.fetch("node_id") }
    assert_includes context_ids, preserved_context.id
    assert_includes context_ids, steered_agent.id
  end

  test "steer_current_turn falls back to interrupt_new_turn when steer is disabled or blocked by side effects" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "steer_capability" => false,
          },
        },
      )
    graph = conversation.dag_graph

    original = conversation.append_user_message!(content: "draft request")
    original_user = original.fetch(:user_node)
    original_agent = original.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [original_agent.id], claimed.map(&:id)

    fallback = conversation.steer_current_turn!(content: "fallback request")
    refute_equal original_user.turn_id, fallback.fetch(:user_node).turn_id
    assert_equal DAG::Node::STOPPED, original_agent.reload.state
    refute original_user.reload.compressed_at.present?

    side_effect_conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "steer_capability" => true,
            "steer_after_side_effects" => false,
          },
        },
      )
    side_effect_graph = side_effect_conversation.dag_graph
    side_effect_lane = side_effect_conversation.chat_lane

    running = side_effect_conversation.append_user_message!(content: "draft request")
    running_user = running.fetch(:user_node)
    running_agent = running.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: side_effect_graph, limit: 10, claimed_by: "test")
    assert_equal [running_agent.id], claimed.map(&:id)

    side_effect_graph.mutate!(turn_id: running_user.turn_id) do |m|
      task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: side_effect_lane.id,
          body_input: { "name" => "write_file" },
          body_output: {
            "result" => AgentCore::Resources::Tools::ToolResult.success(text: "done").to_h,
          },
          metadata: {},
        )
      m.create_edge(from_node: running_agent, to_node: task, edge_type: DAG::Edge::SEQUENCE)
    end

    blocked = side_effect_conversation.steer_current_turn!(content: "fallback request")
    refute_equal running_user.turn_id, blocked.fetch(:user_node).turn_id
    assert_equal DAG::Node::STOPPED, running_agent.reload.state
    refute running_user.reload.compressed_at.present?
  end
end
