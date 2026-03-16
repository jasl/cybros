require "test_helper"

class ConversationBranchingTest < ActionDispatch::IntegrationTest
  setup do
    @workspace_root = Dir.mktmpdir("cybros-branch-workspaces-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  def sign_in_owner!
    email = "branching-#{SecureRandom.hex(4)}@example.com"
    identity =
      Identity.create!(
        email: email,
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: email, password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "branching from a node creates a branch conversation and redirects to it" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    # Create a finished assistant node we can branch from.
    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    agent.mark_running!
    agent.mark_finished!(content: "Hi")

    assert_difference -> { Conversation.count }, +1 do
      post "/conversations/#{conversation.id}/branch", params: { from_node_id: agent.id, title: "Branch" }
    end

    child = Conversation.order(:id).last
    assert_redirected_to conversation_path(child)
    assert_equal conversation.id, child.root_conversation_id
    assert_equal conversation.id, child.parent_conversation_id
    assert_equal agent.id, child.forked_from_node_id
    assert_equal "branch", child.kind
    assert_equal conversation.agent_id, child.agent_id
    assert_equal conversation.agent_config_schema_fingerprint, child.agent_config_schema_fingerprint

    page = child.message_page(limit: 20, mode: :full)

    assert_equal [Messages::AgentMessage.node_type_key], page.fetch("messages").map { |message| message.fetch("node_type") }
    assert_equal ["Hi"], page.fetch("messages").map { |message| message.dig("payload", "output", "content").to_s }
    assert_equal 0, ConversationRun.where(conversation_id: child.id).count
    assert_equal 0,
                 child.root_graph.nodes.active.where(
                   lane_id: child.chat_lane.id,
                   state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
                 ).count
  end

  test "branching snapshots parent conversation memory without copying lane directories" do
    user = sign_in_owner!

    with_default_agent_workspace_root(@workspace_root) do
      conversation = create_conversation!(user: user, title: "Root")
      workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      conversation_path = Pathname.new(workspace.fetch(:conversation_path))
      lane_path =
        Pathname.new(
          Conversations::WorkspaceInitializer.lane_path_for(
            conversation: conversation,
            lane_id: conversation.chat_lane.id,
          ),
        )

      FileUtils.mkdir_p(conversation_path)
      FileUtils.mkdir_p(lane_path)
      File.write(conversation_path.join("MEMORY.md"), "# Parent memory\nship branch takeaways\n")
      File.write(lane_path.join("MEMORY.md"), "# Lane memory\nscratch only\n")

      post conversation_messages_path(conversation), params: { content: "Hello" }
      agent =
        conversation.reload.root_graph.nodes.active
          .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
          .order(:id)
          .last
      agent.mark_running!
      agent.mark_finished!(content: "Hi")

      post "/conversations/#{conversation.id}/branch", params: { from_node_id: agent.id, title: "Branch" }

      child = Conversation.order(:id).last
      child_workspace = Conversations::WorkspaceInitializer.initialize!(conversation: child)
      child_path = Pathname.new(child_workspace.fetch(:conversation_path))

      assert_equal "# Parent memory\nship branch takeaways\n", File.read(child_path.join("MEMORY.md"))
      refute child_path.join(".lanes", child.chat_lane.id, "MEMORY.md").exist?
    end
  end

  test "branching promotes lane memory into parent conversation memory before snapshot without touching root memory" do
    user = sign_in_owner!

    with_default_agent_workspace_root(@workspace_root) do
      conversation = create_conversation!(user: user, title: "Root")
      workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      conversation_path = Pathname.new(workspace.fetch(:conversation_path))
      lane_path =
        Pathname.new(
          Conversations::WorkspaceInitializer.lane_path_for(
            conversation: conversation,
            lane_id: conversation.chat_lane.id,
          ),
        )
      root_memory_path = conversation.agent.workspace_root_path.join("MEMORY.md")

      FileUtils.mkdir_p(conversation_path)
      FileUtils.mkdir_p(lane_path)
      File.write(root_memory_path, "# Root memory\nstay global\n")
      File.write(conversation_path.join("MEMORY.md"), "# Parent memory\nship branch takeaways\n")
      FileUtils.mkdir_p(lane_path.join("memory"))
      File.write(lane_path.join("memory/branch.md"), "# Lane memory\npromote this\n")

      post conversation_messages_path(conversation), params: { content: "Hello" }
      agent =
        conversation.reload.root_graph.nodes.active
          .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
          .order(:id)
          .last
      agent.mark_running!
      agent.mark_finished!(content: "Hi")

      post "/conversations/#{conversation.id}/branch", params: { from_node_id: agent.id, title: "Branch" }

      child = Conversation.order(:id).last
      child_workspace = Conversations::WorkspaceInitializer.initialize!(conversation: child)
      child_path = Pathname.new(child_workspace.fetch(:conversation_path))
      expected_memory = "# Parent memory\nship branch takeaways\n\n# Lane memory\npromote this\n"

      assert_equal expected_memory, File.read(conversation_path.join("MEMORY.md"))
      assert_equal expected_memory, File.read(child_path.join("MEMORY.md"))
      assert_equal "# Root memory\nstay global\n", File.read(root_memory_path)
    end
  end

  test "branching fails when branch memory promotion fails" do
    user = sign_in_owner!

    with_default_agent_workspace_root(@workspace_root) do
      conversation = create_conversation!(user: user, title: "Root")

      post conversation_messages_path(conversation), params: { content: "Hello" }
      agent =
        conversation.reload.root_graph.nodes.active
          .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
          .order(:id)
          .last
      agent.mark_running!
      agent.mark_finished!(content: "Hi")

      original = Conversations::LaneMemoryPromotionService.method(:promote_for_branch!)
      Conversations::LaneMemoryPromotionService.define_singleton_method(:promote_for_branch!) do |**_kwargs|
        raise Cybros::Error, "branch memory promotion failed"
      end

      assert_no_difference -> { Conversation.count } do
        post "/conversations/#{conversation.id}/branch", params: { from_node_id: agent.id, title: "Branch" }
      end

      assert_response :unprocessable_entity
      assert_includes response.body, "branch memory promotion failed"
    ensure
      Conversations::LaneMemoryPromotionService.define_singleton_method(:promote_for_branch!, original)
    end
  end

  test "branching from a user message is rejected" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Root")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    user_node =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last

    assert_no_difference -> { Conversation.count } do
      post "/conversations/#{conversation.id}/branch", params: { from_node_id: user_node.id, title: "Branch" }
    end

    assert_response :unprocessable_entity
  end
end
