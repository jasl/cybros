require "test_helper"

class BootstrapLifecycleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "creating a root conversation dispatches bootstrap hooks and shows an excluded welcome message" do
    conversation = nil

    perform_enqueued_jobs do
      conversation = create_conversation!(title: "Conversation", metadata: { "agent" => { "key" => "main", "agent_profile" => "coding" } })
    end

    assert_equal(
      %w[on_conversation_created],
      AgentRPCInvocation.where(scope_type: "conversation", scope_id: conversation.id).order(:id).pluck(:method),
    )

    welcome =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED)
        .order(:id)
        .last

    assert_equal "cybros_seed_message", welcome.metadata.fetch("generated_by")
    assert_equal "I’m Cybros. I’ll track state in the DAG and keep follow-up work explicit.", welcome.body_output.fetch("content")
    assert welcome.context_excluded?

    page = conversation.message_page(limit: 20, mode: :full)
    page_message = page.fetch("messages").find { |message| message.fetch("node_id") == welcome.id }

    assert_equal Messages::AgentMessage.node_type_key, page_message.fetch("node_type")
    assert_equal "I’m Cybros. I’ll track state in the DAG and keep follow-up work explicit.", page_message.dig("payload", "output", "content")
  end

  test "branch creation with seeded user content dispatches lane-first-user bootstrap and drains title plus summary follow-up" do
    root = nil
    child = nil

    perform_enqueued_jobs do
      root = create_conversation!(title: "Conversation", metadata: { "agent" => { "key" => "main", "agent_profile" => "coding" } })
    end

    from_node = root.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)

    perform_enqueued_jobs do
      child = root.create_child!(from_node_id: from_node.id, kind: "branch", title: "Branch", user_content: "What if we split the runtime hooks?")
    end

    assert_equal(
      %w[on_conversation_created on_lane_first_user_message],
      AgentRPCInvocation.where(scope_type: "conversation", scope_id: child.id).order(:id).pluck(:method),
    )
    assert_equal "What if we split the runtime hooks", child.reload.title
    assert_equal ["cybros_generate_title", "cybros_enqueue_lane_summary"], child.turn_internal_tasks.ordered.pluck(:logical_tool_name)
    assert_equal %w[serial serial], child.turn_internal_tasks.ordered.pluck(:execution_mode)
    assert_equal %w[finished finished], child.turn_internal_tasks.ordered.pluck(:status)
  end

  test "branch lane-first-user bootstrap keeps durable queue rows after the follow-up work is materialized" do
    root = nil
    child = nil

    perform_enqueued_jobs do
      root = create_conversation!(title: "Conversation", metadata: { "agent" => { "key" => "main", "agent_profile" => "coding" } })
    end

    from_node = root.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)

    perform_enqueued_jobs do
      child = root.create_child!(from_node_id: from_node.id, kind: "branch", title: "Branch", user_content: "What if we split the runtime hooks?")
    end

    queue_rows = child.turn_internal_tasks.ordered.to_a

    assert_equal ["cybros_generate_title", "cybros_enqueue_lane_summary"], queue_rows.map(&:logical_tool_name)
    assert_equal %w[serial serial], queue_rows.map(&:execution_mode)
    assert_equal %w[finished finished], queue_rows.map(&:status)
    assert queue_rows.all? { |row| row.materialized_task_node_id.present? }
    assert_equal "What if we split the runtime hooks", child.reload.title
  end

  test "hard-oversize first main-lane user message dispatches only the title hook without a conversation run" do
    conversation = nil

    perform_enqueued_jobs do
      conversation =
        create_conversation!(
          title: "Conversation",
          metadata: {
            "agent" => { "key" => "main", "agent_profile" => "coding" },
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
    end

    first_content = "Design a rollback strategy for deployment failures across the cluster"
    second_content = "Document the follow-up approval flow for emergency changes"

    perform_enqueued_jobs do
      conversation.append_user_message!(content: first_content)
    end

    assert_equal 0, ConversationRun.where(conversation_id: conversation.id).count
    assert_equal first_content, conversation.reload.title
    first_lane_user =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .first
    assert_equal 1,
                 AgentRPCInvocation.where(
                   scope_type: "conversation",
                   scope_id: conversation.id,
                   method: "on_lane_first_user_message",
                 ).count
    assert_equal(
      "conversation:#{conversation.id}:lane:#{conversation.chat_lane.id}:user:" \
      "#{first_lane_user.id}:on_lane_first_user_message",
      AgentRPCInvocation.where(
        scope_type: "conversation",
        scope_id: conversation.id,
        method: "on_lane_first_user_message",
      ).sole.invocation_id,
    )
    assert_equal 0,
                 conversation.root_graph.nodes.active
                   .where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::ERRORED)
                   .where("metadata ->> 'generated_by' = ?", "leaf_invariant")
                   .count
    assert_equal ["cybros_generate_title"], conversation.turn_internal_tasks.ordered.pluck(:logical_tool_name)
    assert_equal ["serial"], conversation.turn_internal_tasks.ordered.pluck(:execution_mode)
    assert_equal ["finished"], conversation.turn_internal_tasks.ordered.pluck(:status)

    perform_enqueued_jobs do
      conversation.append_user_message!(content: second_content)
    end

    assert_equal 1,
                 AgentRPCInvocation.where(
                   scope_type: "conversation",
                   scope_id: conversation.id,
                   method: "on_lane_first_user_message",
                 ).count
    assert_equal first_content, conversation.reload.title
    assert_equal 0,
                 conversation.root_graph.nodes.active
                   .where(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::ERRORED)
                   .where("metadata ->> 'generated_by' = ?", "leaf_invariant")
                   .count
    assert_equal ["cybros_generate_title"], conversation.turn_internal_tasks.ordered.pluck(:logical_tool_name)
    assert_equal ["serial"], conversation.turn_internal_tasks.ordered.pluck(:execution_mode)
    assert_equal ["finished"], conversation.turn_internal_tasks.ordered.pluck(:status)
  end
end
