require "test_helper"
require "tmpdir"

class LaneProcesses::StopperTest < ActiveSupport::TestCase
  test "does not kill a live process when the stored process identity mismatches" do
    Dir.mktmpdir("lane-process-stopper-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!

        lane_process =
          LaneProcesses::Launcher.call!(
            conversation: conversation,
            lane: conversation.chat_lane,
            started_by_type: LaneProcess::AGENT,
            command: "sleep 30",
            title: "Preview server",
          )

        pid = lane_process.pid
        lane_process.update!(summary_json: lane_process.summary_json.merge("process_start_signature" => "wrong-signature"))

        result = LaneProcesses::Stopper.call!(lane_process: lane_process)

        assert_equal "already_exited", result.fetch("status")
        assert_equal LaneProcess::LOST, lane_process.reload.status
        assert process_alive?(pid)
      ensure
        Process.kill("KILL", -pid) if pid.present? && process_alive?(pid)
      end
    end
  end

  test "marks an already exited process as exited" do
    Dir.mktmpdir("lane-process-stopper-exited-test") do |workspace_root|
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
        result = LaneProcesses::Stopper.call!(lane_process: lane_process)

        assert_equal "already_exited", result.fetch("status")
        assert_equal LaneProcess::EXITED, lane_process.reload.status
      end
    end
  end

  private

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
end
