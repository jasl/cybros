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
      assert_equal Pathname.new(@workspace_root).join("claw-#{conversation.agent_id}").cleanpath.to_s, first.fetch(:agent_root_path)
      assert_equal Pathname.new(first.fetch(:agent_root_path)).join("conversations", conversation.id).cleanpath.to_s, first.fetch(:conversation_path)
      assert_equal Pathname.new(first.fetch(:conversation_path)).join(".lanes", conversation.chat_lane.id).cleanpath.to_s, lane_path
      assert_predicate conversation.logical_workspace_initialized_at, :present?
      assert Dir.exist?(first.fetch(:agent_root_path))
      assert Dir.exist?(first.fetch(:conversation_path))
      assert Dir.exist?(lane_path)
    end
  end

  test "initialize! ignores legacy logical workspace metadata when deriving conversation paths" do
    conversation = create_conversation!
    conversation.update_columns(
      logical_workspace_key: "..",
      logical_workspace_root_path: "/tmp/legacy-logical-workspace",
      logical_workspace_initialized_at: 1.day.ago.change(usec: 0),
    )

    with_default_agent_workspace_root(@workspace_root) do
      workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)

      conversation.reload

      assert_equal Pathname.new(@workspace_root).join("claw-#{conversation.agent_id}", "conversations", conversation.id).cleanpath.to_s, workspace.fetch(:conversation_path)
      refute_equal "/tmp/legacy-logical-workspace", workspace.fetch(:conversation_path)
      assert Dir.exist?(workspace.fetch(:conversation_path))
    end
  end
end
