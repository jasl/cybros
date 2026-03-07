require "test_helper"

class ConversationInputGuardTest < ActiveSupport::TestCase
  test "soft single-message oversize inserts a finished compress_input task before the assistant turn" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "oversize" => {
              "single_message" => {
                "soft_threshold_ratio" => 0.00005,
                "hard_threshold_ratio" => 0.001,
              },
            },
          },
        },
      )
    graph = conversation.dag_graph

    result = nil

    assert_difference -> { ConversationRun.count }, +1 do
      result = conversation.append_user_message!(content: "x" * 60)
    end

    user_node = result.fetch(:user_node)
    agent_node = result.fetch(:agent_node)
    refute_nil agent_node

    compress_task =
      graph.nodes.active
        .where(turn_id: agent_node.turn_id, node_type: Messages::Task.node_type_key)
        .order(:id)
        .last

    assert_equal DAG::Node::FINISHED, compress_task.state
    assert_equal "compress_input", compress_task.body_input["name"]
    assert_equal "soft_oversize", compress_task.metadata["generated_by"]
    assert compress_task.body_output["result"].present?

    assert_equal "x" * 60, user_node.body_input["content"]
    assert user_node.context_excluded?
    assert graph.edges.active.exists?(from_node_id: user_node.id, to_node_id: compress_task.id, edge_type: DAG::Edge::SEQUENCE)
    assert graph.edges.active.exists?(from_node_id: compress_task.id, to_node_id: agent_node.id, edge_type: DAG::Edge::SEQUENCE)

    context_ids = conversation.context_for(agent_node.id, mode: :full).map { |node| node.fetch("node_id") }
    refute_includes context_ids, user_node.id
    assert_includes context_ids, compress_task.id
    assert_includes context_ids, agent_node.id
  end

  test "hard single-message oversize persists the raw user message and emits a visible product message without assistant actions" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "oversize" => {
              "single_message" => {
                "soft_threshold_ratio" => 0.00005,
                "hard_threshold_ratio" => 0.0002,
              },
            },
          },
        },
      )

    result = nil

    assert_no_difference -> { ConversationRun.count } do
      result = conversation.append_user_message!(content: "y" * 200)
    end

    user_node = result.fetch(:user_node)
    product_node = result.fetch(:product_node)

    assert_nil result[:agent_node]
    assert_equal "y" * 200, user_node.body_input["content"]
    assert_equal Messages::ProductMessage.node_type_key, product_node.node_type
    assert_equal DAG::Node::FINISHED, product_node.state
    assert_equal "hard_oversize", product_node.metadata["generated_by"]

    page = conversation.message_page(limit: 10, mode: :full)
    page_node_ids = page.fetch("messages").map { |message| message.fetch("node_id") }
    assert_includes page_node_ids, user_node.id
    assert_includes page_node_ids, product_node.id

    product_message = conversation.message_for_node_id(node_id: product_node.id, mode: :full)
    assert_equal Messages::ProductMessage.node_type_key, product_message.fetch("node_type")
    refute product_message.dig("action_policy", "actions", "retry", "supported")
    refute product_message.dig("action_policy", "actions", "regenerate", "supported")
    refute product_message.dig("action_policy", "actions", "stop", "supported")
  end
end
