require "test_helper"
require "socket"
require "tmpdir"

class LaneProcesses::LauncherTest < ActiveSupport::TestCase
  test "cleans up the spawned process if bookkeeping fails after spawn" do
    Dir.mktmpdir("lane-process-launcher-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!
        captured_pid = nil
        singleton = class << Process; self; end
        original_getpgid = singleton.instance_method(:getpgid)

        singleton.send(:define_method, :getpgid) do |pid|
          captured_pid = pid
          raise Errno::EINVAL, "boom"
        end

        error =
          assert_raises(AgentCore::ValidationError) do
            LaneProcesses::Launcher.call!(
              conversation: conversation,
              lane: conversation.chat_lane,
              started_by_type: LaneProcess::AGENT,
              command: "sleep 30",
              title: "Preview server",
            )
          end

        assert_equal "cybros.lane_processes.start_background_process.launch_failed", error.code
        assert captured_pid.present?
        wait_for_process_exit(captured_pid)
        refute process_alive?(captured_pid)
        assert_equal LaneProcess::FAILED, conversation.lane_processes.order(:created_at).last.status
      ensure
        singleton.send(:define_method, :getpgid, original_getpgid)
      end
    end
  end

  test "rejects start when a hinted port is already occupied by an untracked process" do
    Dir.mktmpdir("lane-process-launcher-port-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]

        error =
          assert_raises(AgentCore::ValidationError) do
            LaneProcesses::Launcher.call!(
              conversation: conversation,
              lane: conversation.chat_lane,
              started_by_type: LaneProcess::AGENT,
              command: "sleep 30",
              port_hints: [port],
            )
          end

        assert_equal "cybros.lane_processes.start_background_process.port_conflict", error.code
        assert_equal [port], error.details.fetch(:occupied_ports)
      ensure
        server&.close
      end
    end
  end

  private

    def wait_for_process_exit(pid)
      20.times do
        break unless process_alive?(pid)

        sleep 0.1
      end
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
end
