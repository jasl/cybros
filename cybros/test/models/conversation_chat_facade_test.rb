require "test_helper"

class ConversationChatFacadeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "action_policy_for_node_id returns the app-facing policy dictionary" do
    conversation = create_conversation!(title: "Chat")
    conversation.append_user_message!(content: "Hello")

    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    policy = conversation.action_policy_for_node_id(agent.id)

    assert_equal true, policy.dig("actions", "regenerate", "available")
    assert_equal "in_place", policy.dig("actions", "regenerate", "mode")
    assert_equal true, policy.dig("actions", "swipe", "available")
  end

  test "message_for_node_id includes action_policy" do
    conversation = create_conversation!(title: "Chat")
    conversation.append_user_message!(content: "Hello")

    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    message = conversation.message_for_node_id(node_id: agent.id, mode: :full)

    assert_equal agent.id, message.fetch("node_id")
    assert_equal true, message.dig("action_policy", "actions", "regenerate", "available")
    assert_equal "in_place", message.dig("action_policy", "actions", "regenerate", "mode")
  end

  test "stop_node! stops a pending agent in the active lane" do
    conversation = create_conversation!(title: "Chat")
    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent.id)

    conversation.stop_node!(node_id: agent.id)

    assert_equal DAG::Node::STOPPED, agent.reload.state
    assert_equal "user_cancelled", agent.metadata["reason"]
    assert_equal "canceled", run.reload.state
  end

  test "message_page keeps awaiting approval agent nodes visible in the transcript" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.dag_graph

    user = nil
    agent = nil

    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Needs approval",
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::AWAITING_APPROVAL,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    page = conversation.message_page(limit: 20, mode: :full)
    message = page.fetch("messages").find { |entry| entry.fetch("node_id") == agent.id }

    assert message.present?
    assert_equal DAG::Node::AWAITING_APPROVAL, message.fetch("state")
  end

  test "message_for_node_id and stop_node! reject nodes from a different lane" do
    root = create_conversation!(title: "Root")

    first_turn = root.append_user_message!(content: "Hello")
    first_agent = first_turn.fetch(:agent_node)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Done")

    branch = root.create_child!(from_node_id: first_agent.id, kind: "branch", title: "Branch", user_content: "What if?")

    second_turn = root.append_user_message!(content: "Root followup")
    root_agent = second_turn.fetch(:agent_node)
    root_agent.mark_running!

    assert_raises(ActiveRecord::RecordNotFound) do
      branch.message_for_node_id(node_id: root_agent.id, mode: :full)
    end

    assert_raises(ActiveRecord::RecordNotFound) do
      branch.stop_node!(node_id: root_agent.id)
    end
  end

  test "message_page hides regenerate for non-tail assistants while keeping branch available" do
    conversation = create_conversation!(title: "Chat")

    conversation.append_user_message!(content: "Hello")
    first_agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Hi v1")

    conversation.append_user_message!(content: "Followup")
    second_agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    second_agent.mark_running!
    second_agent.mark_finished!(content: "Hi v2")

    page = conversation.message_page(limit: 20, mode: :full)
    first_message = page.fetch("messages").find { |message| message.fetch("node_id") == first_agent.id }

    assert_equal false, first_message.dig("action_policy", "actions", "regenerate", "available")
    assert_equal "history_requires_branch", first_message.dig("action_policy", "actions", "regenerate", "reason")
    assert_equal true, first_message.dig("action_policy", "actions", "branch", "available")
    assert_equal false, first_message.dig("action_policy", "actions", "swipe", "available")
  end

  test "append_user_message! creates user + pending agent and enqueues a run" do
    conversation = create_conversation!(title: "Chat")

    assert_difference -> { conversation.root_graph.nodes.count }, +2 do
      assert_difference -> { ConversationRun.count }, +1 do
        conversation.append_user_message!(content: "Hello")
      end
    end

    lane = conversation.chat_lane
    graph = conversation.root_graph

    user = graph.nodes.active.where(lane_id: lane.id, node_type: Messages::UserMessage.node_type_key).order(:id).last
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last

    assert_equal DAG::Node::FINISHED, user.state
    assert_equal "Hello", user.body_input.fetch("content")

    assert_equal Messages::AgentMessage.node_type_key, agent.node_type
    assert_equal DAG::Node::PENDING, agent.state

    run = ConversationRun.order(:id).last
    assert_equal conversation.id, run.conversation_id
    assert_equal agent.id, run.dag_node_id
    assert_equal "queued", run.state
  end

  test "append_user_message! silently repairs a stale pending tail before building the next turn" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first = conversation.append_user_message!(content: "u1")
    first_user = first.fetch(:user_node)
    stale_agent = first.fetch(:agent_node)
    stale_run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: stale_agent.id)

    second = conversation.append_user_message!(content: "u2")
    second_user = second.fetch(:user_node)
    second_agent = second.fetch(:agent_node)

    assert_equal DAG::Node::STOPPED, stale_agent.reload.state
    assert stale_agent.deleted?
    assert stale_agent.context_excluded?
    assert_equal "canceled", stale_run.reload.state

    sequence_parent_id =
      conversation.root_graph.edges.active
        .where(to_node_id: second_user.id, edge_type: DAG::Edge::SEQUENCE)
        .order(:id)
        .pick(:from_node_id)
    assert_equal first_user.id, sequence_parent_id
    refute conversation.root_graph.edges.active.exists?(from_node_id: stale_agent.id, to_node_id: second_user.id, edge_type: DAG::Edge::SEQUENCE)
    refute conversation.root_graph.edges.active.exists?(from_node_id: stale_agent.id, to_node_id: second_agent.id, edge_type: DAG::Edge::DEPENDENCY)

    page = conversation.message_page(limit: 20, mode: :full)
    refute_includes page.fetch("messages").map { |message| message.fetch("node_id") }, stale_agent.id
  end

  test "start_pending_agent_node! claims the tail pending assistant and enqueues execution" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    agent = conversation.append_user_message!(content: "Hello").fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent.id)
    clear_enqueued_jobs

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [agent.id]) do
      conversation.start_pending_agent_node!(node_id: agent.id, claimed_by: "manual-start:test")
    end

    assert_equal DAG::Node::RUNNING, agent.reload.state
    assert_equal "manual-start:test", agent.claimed_by
    assert agent.claimed_at.present?
    assert_nil agent.started_at
    assert_equal "queued", run.reload.state
  end

  test "start_pending_agent_node! silently repairs stale middle pending agents before claiming the tail" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first = conversation.append_user_message!(content: "u1")
    stale_agent = first.fetch(:agent_node)
    stale_run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: stale_agent.id)
    second = conversation.append_user_message!(content: "u2", repair_pending_tail: false)
    tail_agent = second.fetch(:agent_node)

    clear_enqueued_jobs

    assert_enqueued_with(job: DAG::ExecuteNodeJob, args: [tail_agent.id]) do
      conversation.start_pending_agent_node!(node_id: tail_agent.id, claimed_by: "manual-start:test")
    end

    assert_equal DAG::Node::STOPPED, stale_agent.reload.state
    assert stale_agent.deleted?
    assert stale_agent.context_excluded?
    assert_equal "canceled", stale_run.reload.state

    assert_equal DAG::Node::RUNNING, tail_agent.reload.state
    sequence_parent_id =
      conversation.root_graph.edges.active
        .where(to_node_id: second.fetch(:user_node).id, edge_type: DAG::Edge::SEQUENCE)
        .order(:id)
        .pick(:from_node_id)
    assert_equal first.fetch(:user_node).id, sequence_parent_id
  end

  test "create_child! forks a lane and attaches it to a branch conversation" do
    conversation = create_conversation!(title: "Root")
    graph = conversation.root_graph
    main_lane = conversation.chat_lane

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    child =
      conversation.create_child!(
        from_node_id: agent.id,
        kind: "branch",
        title: "Branch",
        user_content: "What if?",
      )

    assert_equal "branch", child.kind
    assert_equal conversation.id, child.parent_conversation_id
    assert_equal conversation.id, child.root_conversation_id
    assert_equal agent.id, child.forked_from_node_id

    lane = child.chat_lane
    assert_equal DAG::Lane::BRANCH, lane.role
    assert_equal main_lane.id, lane.parent_lane_id
    assert_equal child, lane.attachable
  end

  test "create_child! snapshots lane scoped state into the child lane" do
    conversation = create_conversation!(title: "Root")
    graph = conversation.root_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    LaneKVEntry.create!(
      lane: conversation.chat_lane,
      key: "shared.stage",
      value: { "status" => "planned" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    LanePromptBufferEntry.create!(
      lane: conversation.chat_lane,
      buffer_name: "summaries",
      seq: 10,
      kind: "summary",
      content: "Parent summary",
      estimated_tokens: 12,
      metadata: { "source" => "test" },
    )

    child =
      conversation.create_child!(
        from_node_id: agent.id,
        kind: "branch",
        title: "Branch",
        user_content: "What if?",
      )

    assert_equal(
      [{ "key" => "shared.stage", "value" => { "status" => "planned" } }],
      child.chat_lane.lane_kv_entries.order(:key).map { |entry| { "key" => entry.key, "value" => entry.value } },
    )
    assert_equal(
      [{
        "buffer_name" => "summaries",
        "seq" => 10,
        "kind" => "summary",
        "content" => "Parent summary",
        "estimated_tokens" => 12,
      }],
      child.chat_lane.lane_prompt_buffer_entries.ordered.map do |entry|
        {
          "buffer_name" => entry.buffer_name,
          "seq" => entry.seq,
          "kind" => entry.kind,
          "content" => entry.content,
          "estimated_tokens" => entry.estimated_tokens,
        }
      end,
    )
  end

  test "child lane snapshot stays independent after parent lane state changes" do
    conversation = create_conversation!(title: "Root")
    graph = conversation.root_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    root_entry =
      LaneKVEntry.create!(
        lane: conversation.chat_lane,
        key: "shared.stage",
        value: { "status" => "planned" },
        written_by_type: "Seed",
        written_by_id: SecureRandom.uuid,
      )
    LanePromptBufferEntry.create!(
      lane: conversation.chat_lane,
      buffer_name: "working_notes",
      seq: 10,
      kind: "note",
      content: "Before fork",
      estimated_tokens: 8,
    )

    child =
      conversation.create_child!(
        from_node_id: agent.id,
        kind: "branch",
        title: "Branch",
        user_content: "What if?",
      )

    root_entry.update!(value: { "status" => "updated-after-fork" })
    LanePromptBufferEntry.create!(
      lane: conversation.chat_lane,
      buffer_name: "working_notes",
      seq: 20,
      kind: "note",
      content: "After fork",
      estimated_tokens: 9,
    )

    assert_equal({ "status" => "planned" }, child.chat_lane.lane_kv_entries.find_by!(key: "shared.stage").value)
    assert_equal ["Before fork"], child.chat_lane.lane_prompt_buffer_entries.ordered.pluck(:content)
  end

  test "edit_user_message! replaces the latest user turn and queues a regenerated assistant" do
    conversation = create_conversation!(title: "Chat")

    first = conversation.append_user_message!(content: "Hello")
    original_user = first.fetch(:user_node)
    original_agent = first.fetch(:agent_node)
    original_agent.mark_running!
    original_agent.mark_finished!(content: "Hi")

    result = conversation.edit_user_message!(node_id: original_user.id, content: "Hello again")
    edited_user = result.fetch(:user_node)
    regenerated_agent = result.fetch(:agent_node)

    assert_equal original_user.turn_id, edited_user.turn_id
    assert_equal "Hello again", edited_user.body_input.fetch("content")
    assert_equal DAG::Node::PENDING, regenerated_agent.state
    assert_equal conversation.id, ConversationRun.find_by!(dag_node_id: regenerated_agent.id).conversation_id

    assert original_user.reload.compressed_at.present?
    assert original_agent.reload.compressed_at.present?

    visible_inputs =
      conversation.message_page(limit: 20, mode: :full).fetch("messages").filter_map do |message|
        message.dig("payload", "input", "content").to_s.presence
      end

    assert_equal ["Hello again"], visible_inputs
  end

  test "edit_user_message! rejects editing a user turn that already has attachments" do
    conversation = create_conversation!(title: "Chat")
    attachment =
      Rack::Test::UploadedFile.new(
        Rails.root.join("test/fixtures/files/attachment-note.txt"),
        "text/plain",
      )

    result =
      conversation.append_user_message!(
        content: "",
        attachments: [attachment],
      )
    original_user = result.fetch(:user_node)
    original_agent = result.fetch(:agent_node)
    original_agent.mark_running!
    original_agent.mark_finished!(content: "Attachment received")

    error =
      assert_raises(Cybros::Error) do
        conversation.edit_user_message!(node_id: original_user.id, content: "Edited")
      end

    assert_equal "Editing attachments is not supported yet.", error.message
    assert_equal [original_user.id], conversation.root_graph.nodes.active.where(turn_id: original_user.turn_id, node_type: Messages::UserMessage.node_type_key).pluck(:id)
    assert_equal ["attachment-note.txt"], original_user.reload.body_input.fetch("attachments").map { |entry| entry.fetch("filename") }
    assert_equal 1, conversation.conversation_attachments.where(source_message_node_id: original_user.id).count
  end

  test "select_swipe! adopts a previous version in the same version_set" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "v1")

    regen = conversation.regenerate!(agent_node_id: agent.id)
    assert_equal :in_place, regen.fetch(:mode)

    new_agent = regen.fetch(:node)
    new_agent.mark_running!
    new_agent.mark_finished!(content: "v2")
    assert_equal agent.version_set_id, new_agent.version_set_id
    assert_nil new_agent.compressed_at
    assert agent.reload.compressed_at.present?

    selected = conversation.select_swipe!(agent_node_id: new_agent.id, direction: :left)
    assert_equal agent.id, selected.id
    assert_nil selected.compressed_at
    assert new_agent.reload.compressed_at.present?
  end

  test "select_swipe! can adopt a previous version when both versions are followed only by leaf-terminal authority tasks" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "v1")

    graph.mutate! do |m|
      task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          metadata: {
            "authored_metadata" => {
              "leaf_terminal" => true,
            },
          },
          body_input: {
            "name" => "cybros_generate_title",
          },
        )

      m.create_edge(from_node: agent, to_node: task, edge_type: DAG::Edge::SEQUENCE)
    end

    regen = conversation.regenerate!(agent_node_id: agent.id)
    new_agent = regen.fetch(:node)
    new_agent.mark_running!
    new_agent.mark_finished!(content: "v2")

    selected = conversation.select_swipe!(agent_node_id: new_agent.id, direction: :left)

    assert_equal agent.id, selected.id
    assert_nil selected.reload.compressed_at
    assert new_agent.reload.compressed_at.present?
  end

  test "soft_delete_node! cancels queued run for that node" do
    conversation = create_conversation!(title: "Chat")
    result = conversation.append_user_message!(content: "Hello")
    agent = result.fetch(:agent_node)

    run = ConversationRun.order(:id).last
    assert_equal "queued", run.state
    assert_equal agent.id, run.dag_node_id

    conversation.soft_delete_node!(node_id: agent.id)

    agent.reload
    assert_equal DAG::Node::STOPPED, agent.state
    assert agent.deleted?
    assert_nil DAG::NodeVisibilityPatch.find_by(graph_id: agent.graph_id, node_id: agent.id),
               "expected no deferred visibility patch when the node can be stopped and deleted immediately"
    assert_equal "canceled", run.reload.state
  end

  test "cancel_queued_turn! rebuilds the remaining queued turns in order" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first = conversation.append_user_message!(content: "u1")
    first_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    second = conversation.append_user_message!(content: "u2")
    third = conversation.append_user_message!(content: "u3")
    fourth = conversation.append_user_message!(content: "u4")

    conversation.cancel_queued_turn!(user_node_id: third.fetch(:user_node).id)

    assert_equal %w[u2 u4], conversation.composer_state.dig("queue", "items").map { |item| item.fetch("content") }
    assert conversation.root_graph.nodes.active.where(turn_id: third.fetch(:user_node).turn_id).empty?
    assert_equal [], DAG::GraphAudit.scan(graph: conversation.root_graph)
  end

  test "message_page hides queued turns that are already summarized in the composer queue" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first = conversation.append_user_message!(content: "u1")
    first_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    queued = conversation.append_user_message!(content: "queued follow up")

    assert_equal ["queued follow up"], conversation.composer_state.dig("queue", "items").map { |item| item.fetch("content") }

    transcript_inputs =
      conversation.message_page(limit: 20, mode: :full).fetch("messages").filter_map do |message|
        message.dig("payload", "input", "content").to_s.presence
      end

    refute_includes transcript_inputs, queued.fetch(:user_node).body_input.fetch("content")
  end

  test "steer_queued_turn! applies the selected queued content and preserves the remaining queue" do
    conversation =
      create_conversation!(
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    first = conversation.append_user_message!(content: "u1")
    first_user = first.fetch(:user_node)
    first_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test")
    assert_equal [first_agent.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    second = conversation.append_user_message!(content: "u2")
    third = conversation.append_user_message!(content: "u3")
    fourth = conversation.append_user_message!(content: "u4")

    conversation.steer_queued_turn!(user_node_id: third.fetch(:user_node).id)

    active_current_user =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, turn_id: first_user.turn_id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last

    assert_equal "u3", active_current_user.body_input.fetch("content")
    assert_equal %w[u2 u4], conversation.composer_state.dig("queue", "items").map { |item| item.fetch("content") }
    assert conversation.root_graph.nodes.active.where(turn_id: third.fetch(:user_node).turn_id).empty?
    assert_equal [], DAG::GraphAudit.scan(graph: conversation.root_graph)
  end

  test "translate! marks node metadata pending and clear_translations! removes it" do
    conversation = create_conversation!(title: "Chat")
    result = conversation.append_user_message!(content: "Hello")
    user_node = result.fetch(:user_node)

    conversation.translate!(node_id: user_node.id, target_lang: "zh-CN")
    user_node.reload

    pending = user_node.metadata.dig("i18n", "translation_pending", "zh-CN")
    assert_equal true, pending

    conversation.clear_translations!
    user_node.reload
    refute user_node.metadata.dig("i18n", "translation_pending", "zh-CN")
  end

  test "merge_into_parent! merges a branch lane into its parent lane" do
    root = create_conversation!(title: "Root")
    graph = root.root_graph

    root.append_user_message!(content: "Hello")
    main_lane = root.chat_lane
    main_agent = graph.leaf_nodes.where(lane_id: main_lane.id).order(:id).last
    main_agent.mark_running!
    main_agent.mark_finished!(content: "Done")

    branch = root.create_child!(from_node_id: main_agent.id, kind: "branch", title: "Branch", user_content: "What if?")
    branch_lane = branch.chat_lane
    root.chat_lane.lane_kv_entries.create!(
      key: "shared.stage",
      value: { "status" => "main" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    branch_lane.lane_kv_entries.create!(
      key: "shared.stage",
      value: { "status" => "branch" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    branch_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "note",
      content: "Branch handoff",
      priority: 50,
      estimated_tokens: 7,
    )

    # Continue main after branching so the parent lane has a current head.
    root.append_user_message!(content: "Main followup")
    main_agent_2 = graph.leaf_nodes.where(lane_id: main_lane.id).order(:id).last
    main_agent_2.mark_running!
    main_agent_2.mark_finished!(content: "Main done")

    # Ensure the branch has a terminal head.
    branch.append_user_message!(content: "Branch followup")
    branch_agent = graph.leaf_nodes.where(lane_id: branch_lane.id).order(:id).last
    branch_agent.mark_running!
    branch_agent.mark_finished!(content: "Branch done")

    merge = branch.merge_into_parent!(metadata: { "reason" => "test" })
    args = merge.body_input.fetch("arguments")

    assert_equal main_lane.id, merge.lane_id
    assert_equal Messages::Task.node_type_key, merge.node_type
    assert_equal DAG::Node::PENDING, merge.state
    assert_equal "merge_lane_state", merge.body_input["name"]
    assert_equal main_lane.id, args.fetch("target_lane_id")
    assert_equal [branch_lane.id], args.fetch("source_lane_ids")
    assert_equal "test", args.dig("merge_metadata", "reason")
    assert_equal root.send(:lane_state_snapshot, lane: main_lane).fetch("kv_entries"), args.fetch("target_lane_kv_snapshot")
    assert_equal root.send(:lane_state_snapshot, lane: branch_lane).fetch("prompt_buffer_entries"), args.fetch("source_prompt_buffer_snapshots").sole.fetch("entries")

    branch_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "mutated_after_merge_request" })
    LanePromptBufferEntry.create!(
      lane: branch_lane,
      buffer_name: "handoff",
      seq: 20,
      kind: "note",
      content: "Late branch note",
      priority: 10,
      estimated_tokens: 5,
    )

    assert_equal({ "status" => "branch" }, args.fetch("source_lane_kv_snapshots").sole.fetch("entries").sole.fetch("value"))
    assert_equal ["Branch handoff"], args.fetch("source_prompt_buffer_snapshots").sole.fetch("entries").map { |entry| entry.fetch("content") }
  end

  test "message_page includes only the active version after regenerate" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "v1")

    regen = conversation.regenerate!(agent_node_id: agent.id)
    new_agent = regen.fetch(:node)
    new_agent.mark_running!
    new_agent.mark_finished!(content: "v2")

    page = lane.message_page(limit: 50, mode: :preview)
    message_ids = page.fetch("message_ids")

    assert_includes message_ids, new_agent.id
    refute_includes message_ids, agent.id
  end

  test "select_swipe! raises while there is an in-flight (pending) version" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "v1")

    regen = conversation.regenerate!(agent_node_id: agent.id)
    new_agent = regen.fetch(:node)
    assert_equal DAG::Node::PENDING, new_agent.state

    assert_raises(Cybros::Error) do
      conversation.select_swipe!(agent_node_id: new_agent.id, direction: :left)
    end
  end

  test "select_swipe!(position:) accepts 1-based version_number and version_id" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent_v1 = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent_v1.mark_running!
    agent_v1.mark_finished!(content: "v1")

    regen = conversation.regenerate!(agent_node_id: agent_v1.id)
    agent_v2 = regen.fetch(:node)
    agent_v2.mark_running!
    agent_v2.mark_finished!(content: "v2")

    # By version_number (1-based)
    selected = conversation.select_swipe!(agent_node_id: agent_v2.id, position: 1)
    assert_equal agent_v1.id, selected.id

    # By explicit version_id
    selected2 = conversation.select_swipe!(agent_node_id: selected.id, position: agent_v2.id)
    assert_equal agent_v2.id, selected2.id
  end

  test "create_child! refuses to fork from non-forkable node types" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    bad = nil
    graph.mutate! do |m|
      bad =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "result"
        )
    end

    assert_raises(Cybros::Error) do
      conversation.create_child!(from_node_id: bad.id, kind: "branch", title: "Branch", user_content: "hi")
    end
  end

  test "create_child! refuses to fork from a deleted node" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    from_node = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    from_node.mark_running!
    from_node.mark_finished!(content: "Done")
    from_node.soft_delete!

    assert_raises(Cybros::Error) do
      conversation.create_child!(from_node_id: from_node.id, kind: "branch", title: "Branch", user_content: "hi")
    end
  end

  test "create_child! refuses to fork from a node in a different lane" do
    root = create_conversation!(title: "Root")
    graph = root.root_graph
    main_lane = root.chat_lane

    root.append_user_message!(content: "Hello")
    main_agent = graph.leaf_nodes.where(lane_id: main_lane.id).order(:id).last
    main_agent.mark_running!
    main_agent.mark_finished!(content: "Done")

    branch = root.create_child!(from_node_id: main_agent.id, kind: "branch", title: "Branch", user_content: "Hi")
    branch_lane = branch.chat_lane
    branch_root_node = graph.nodes.active.where(lane_id: branch_lane.id).order(:id).first

    assert_raises(ArgumentError) do
      root.create_child!(from_node_id: branch_root_node.id, kind: "branch", title: "Branch2", user_content: "Hi")
    end
  end

  test "select_swipe! refuses to adopt a deleted version" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent_v1 = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent_v1.mark_running!
    agent_v1.mark_finished!(content: "v1")

    regen = conversation.regenerate!(agent_node_id: agent_v1.id)
    agent_v2 = regen.fetch(:node)
    agent_v2.mark_running!
    agent_v2.mark_finished!(content: "v2")

    agent_v1.soft_delete!

    assert_raises(Cybros::Error) do
      conversation.select_swipe!(agent_node_id: agent_v2.id, position: agent_v1.id)
    end
  end

  test "regenerate! refuses to regenerate a deleted agent node" do
    conversation = create_conversation!(title: "Chat")
    graph = conversation.root_graph
    lane = conversation.chat_lane

    conversation.append_user_message!(content: "Hello")
    agent = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
    agent.mark_running!
    agent.mark_finished!(content: "v1")
    agent.soft_delete!

    assert_raises(Cybros::Error) do
      conversation.regenerate!(agent_node_id: agent.id)
    end
  end
end
