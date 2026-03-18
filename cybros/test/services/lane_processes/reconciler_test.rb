require "test_helper"
require "tmpdir"

class LaneProcesses::ReconcilerTest < ActiveSupport::TestCase
  test "marks a naturally exited process as exited" do
    Dir.mktmpdir("lane-process-reconciler-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!

        lane_process =
          LaneProcesses::Launcher.call!(
            conversation: conversation,
            lane: conversation.chat_lane,
            started_by_type: LaneProcess::AGENT,
            command: "sleep 0.2",
            title: "Short task",
          )

        sleep 0.4
        LaneProcesses::Reconciler.call!(conversation: conversation)

        assert_equal LaneProcess::EXITED, lane_process.reload.status
        assert lane_process.ended_at.present?
      end
    end
  end

  test "marks stale starting rows without a pid as lost" do
    conversation = create_conversation!

    lane_process =
      LaneProcess.create!(
        conversation: conversation,
        lane: conversation.chat_lane,
        status: LaneProcess::STARTING,
        started_by_type: LaneProcess::AGENT,
        title: "Stuck start",
        command: "bin/dev",
        started_at: 1.minute.ago,
        last_seen_at: 1.minute.ago,
      )

    LaneProcesses::Reconciler.call!(conversation: conversation)

    assert_equal LaneProcess::LOST, lane_process.reload.status
    assert lane_process.ended_at.present?
  end
end
