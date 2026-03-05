require "test_helper"

class ConversationChatFacadeTest < ActiveSupport::TestCase
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

  test "create_child! forks a lane and attaches it to a child conversation" do
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
    assert_equal main_lane.id, merge.lane_id
    assert_equal DAG::Node::PENDING, merge.state
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
