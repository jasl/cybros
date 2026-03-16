require "test_helper"

class ConversationProgramSelectionTest < ActiveSupport::TestCase
  test "new conversations default to the bundled claw agent" do
    assert defined?(Agent), "expected Agent to be the public conversation binding"
    assert_equal :agent, Conversation.reflect_on_association(:agent)&.name
    assert_nil Conversation.reflect_on_association(:agent_program)
    assert_nil Conversation.reflect_on_association(:default_execution_target)
  end

  test "conversation workspace helpers resolve under the agent root instead of legacy logical workspace metadata" do
    workspace_root = Dir.mktmpdir("cybros-conversation-model-")
    conversation = create_conversation!(title: "Workspace contract")
    conversation.update_columns(
      logical_workspace_key: "legacy-key",
      logical_workspace_root_path: "/tmp/legacy-logical-workspace",
      logical_workspace_initialized_at: 2.days.ago.change(usec: 0),
    )

    with_default_agent_workspace_root(workspace_root) do
      assert_equal Pathname.new(workspace_root).join("claw-#{conversation.agent_id}").cleanpath, conversation.agent.workspace_root_path
      assert_equal conversation.agent.workspace_root_path.join("conversations", conversation.id), conversation.workspace_root_path
      assert_equal conversation.workspace_root_path.join(".lanes", conversation.chat_lane.id), conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id)
      refute_equal Pathname.new("/tmp/legacy-logical-workspace"), conversation.workspace_root_path
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end
end
