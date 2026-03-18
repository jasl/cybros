require "test_helper"
require "tmpdir"

class ConversationLaneProcessesTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path

    user
  end

  test "user stop route kills a tracked background process" do
    Dir.mktmpdir("conversation-lane-processes-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        user = sign_in_owner!
        conversation = create_conversation!(user: user, title: "Chat")

        lane_process =
          LaneProcesses::Launcher.call!(
            conversation: conversation,
            lane: conversation.chat_lane,
            started_by_type: LaneProcess::AGENT,
            command: "sleep 30",
            title: "Preview server",
          )

        post stop_conversation_lane_process_path(conversation, lane_process)

        assert_redirected_to conversation_path(conversation)
        assert_equal "killed", lane_process.reload.status
        assert lane_process.ended_at.present?
      end
    end
  end
end
