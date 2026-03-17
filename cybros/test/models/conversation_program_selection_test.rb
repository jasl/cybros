require "test_helper"

class ConversationProgramSelectionTest < ActiveSupport::TestCase
  test "new conversations default to the bundled claw agent" do
    assert defined?(Agent), "expected Agent to be the public conversation binding"
    assert_equal :agent, Conversation.reflect_on_association(:agent)&.name
    assert_nil Conversation.reflect_on_association(:agent_program)
    assert_nil Conversation.reflect_on_association(:default_execution_target)
    refute_includes Conversation.column_names, "logical_workspace_key"
    refute_includes Conversation.column_names, "logical_workspace_root_path"
    refute_includes Conversation.column_names, "logical_workspace_initialized_at"
  end

  test "conversation workspace helpers resolve under the agent root" do
    workspace_root = Dir.mktmpdir("cybros-conversation-model-")
    conversation = create_conversation!(title: "Workspace contract")

    with_default_agent_workspace_root(workspace_root) do
      assert_equal Pathname.new(workspace_root).join("bundled/claw").cleanpath, conversation.agent.workspace_root_path
      assert_equal conversation.agent.workspace_root_path.join("conversations", conversation.id), conversation.workspace_root_path
      assert_equal conversation.workspace_root_path.join(".lanes", conversation.chat_lane.id), conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id)
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end
end
