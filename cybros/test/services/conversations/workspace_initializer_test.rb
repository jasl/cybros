require "test_helper"

class Conversations::WorkspaceInitializerTest < ActiveSupport::TestCase
  setup do
    @workspace_root = Dir.mktmpdir("cybros-conversation-workspaces-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  test "initialize! resolves stable conversation and lane paths under the agent root and materializes the working directories" do
    conversation = create_conversation!

    with_default_agent_workspace_root(@workspace_root) do
      first = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      second = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      lane_path = Conversations::WorkspaceInitializer.lane_path_for(
        conversation: conversation,
        lane_id: conversation.chat_lane.id,
      )

      conversation.reload

      assert_equal first.fetch(:agent_root_path), second.fetch(:agent_root_path)
      assert_equal first.fetch(:conversation_path), second.fetch(:conversation_path)
      assert_equal Pathname.new(@workspace_root).join("bundled", "claw").cleanpath.to_s, first.fetch(:agent_root_path)
      assert_equal Pathname.new(first.fetch(:agent_root_path)).join("conversations", conversation.id).cleanpath.to_s, first.fetch(:conversation_path)
      assert_equal Pathname.new(first.fetch(:conversation_path)).join(".lanes", conversation.chat_lane.id).cleanpath.to_s, lane_path
      refute first.key?(:root_path)
      assert_equal first.fetch(:cwd), first.fetch(:conversation_path)
      assert Dir.exist?(first.fetch(:agent_root_path))
      assert Dir.exist?(first.fetch(:conversation_path))
      assert Dir.exist?(lane_path)
    end
  end

  test "initialize! derives conversation paths from the agent root" do
    conversation = create_conversation!

    with_default_agent_workspace_root(@workspace_root) do
      workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)

      assert_equal Pathname.new(@workspace_root).join("bundled", "claw", "conversations", conversation.id).cleanpath.to_s, workspace.fetch(:conversation_path)
      assert Dir.exist?(workspace.fetch(:conversation_path))
    end
  end
end
