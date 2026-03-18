require "test_helper"
require "tmpdir"

class LaneProcesses::LogReaderTest < ActiveSupport::TestCase
  test "returns only the requested tail lines" do
    Dir.mktmpdir("lane-process-log-reader-test") do |dir|
      log_path = File.join(dir, "combined.log")
      File.write(log_path, (1..100).map { |n| "line-#{n}" }.join("\n") + "\n")
      conversation = create_conversation!

      lane_process =
        LaneProcess.new(
          conversation: conversation,
          lane: conversation.chat_lane,
          status: LaneProcess::RUNNING,
          started_by_type: LaneProcess::AGENT,
          log_path: log_path,
        )

      lines = LaneProcesses::LogReader.call(lane_process: lane_process, tail_lines: 3)

      assert_equal %w[line-98 line-99 line-100], lines
    end
  end
end
