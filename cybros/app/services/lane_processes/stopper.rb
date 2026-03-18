module LaneProcesses
  class Stopper
    TERM_WAIT_SECONDS = 1.0
    POLL_INTERVAL_SECONDS = 0.1

    def self.call!(lane_process:)
      new(lane_process: lane_process).call!
    end

    def initialize(lane_process:)
      @lane_process = lane_process
    end

    def call!
      return { "status" => "already_terminated", "lane_process_id" => lane_process.id } if lane_process.terminal?

      case LaneProcesses::ProcessRuntime.identity_state(lane_process)
      when :missing_pid, :mismatch
        return mark_lost!
      when :dead
        return mark_exited!
      end

      LaneProcesses::ProcessRuntime.signal_process_group(lane_process, "TERM")
      wait_for_exit(timeout_seconds: TERM_WAIT_SECONDS)
      LaneProcesses::ProcessRuntime.signal_process_group(lane_process, "KILL") if LaneProcesses::ProcessRuntime.identity_state(lane_process) == :alive
      wait_for_exit(timeout_seconds: TERM_WAIT_SECONDS)

      if LaneProcesses::ProcessRuntime.identity_state(lane_process) == :alive
        AgentCore::ValidationError.raise!(
          "Background process could not be stopped.",
          code: "cybros.lane_processes.stop_lane_process.stop_failed",
          details: { lane_process_id: lane_process.id },
        )
      end

      now = Time.current
      lane_process.update!(
        status: LaneProcess::KILLED,
        ended_at: now,
        last_seen_at: now,
      )

      {
        "status" => "killed",
        "lane_process_id" => lane_process.id,
      }
    end

    private

      attr_reader :lane_process

      def mark_lost!
        now = Time.current
        lane_process.update!(
          status: LaneProcess::LOST,
          ended_at: now,
          last_seen_at: now,
        )

        {
          "status" => "already_exited",
          "lane_process_id" => lane_process.id,
        }
      end

      def wait_for_exit(timeout_seconds:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
        while LaneProcesses::ProcessRuntime.identity_state(lane_process) == :alive && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep POLL_INTERVAL_SECONDS
        end
      end

      def mark_exited!
        now = Time.current
        lane_process.update!(
          status: LaneProcess::EXITED,
          ended_at: now,
          last_seen_at: now,
        )

        {
          "status" => "already_exited",
          "lane_process_id" => lane_process.id,
        }
      end
  end
end
