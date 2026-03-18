module LaneProcesses
  class Reconciler
    STARTING_STALE_AFTER = 15.seconds
    TOUCH_INTERVAL = 15.seconds

    def self.call!(conversation:)
      new(conversation: conversation).call!
    end

    def initialize(conversation:)
      @conversation = conversation
    end

    def call!
      conversation.lane_processes.active.find_each do |lane_process|
        reconcile!(lane_process)
      end
    end

    private

      attr_reader :conversation

      def reconcile!(lane_process)
        case LaneProcesses::ProcessRuntime.identity_state(lane_process)
        when :missing_pid
          return unless lane_process.started_at.present? && lane_process.started_at <= STARTING_STALE_AFTER.ago

          mark_lost!(lane_process)
        when :dead
          mark_exited!(lane_process)
        when :mismatch
          mark_lost!(lane_process)
        when :alive
          return if lane_process.last_seen_at.present? && lane_process.last_seen_at >= TOUCH_INTERVAL.ago

          lane_process.update_columns(last_seen_at: Time.current, updated_at: Time.current)
        end
      end

      def mark_lost!(lane_process)
        now = Time.current
        lane_process.update_columns(
          status: LaneProcess::LOST,
          ended_at: lane_process.ended_at || now,
          last_seen_at: now,
          updated_at: now,
        )
      end

      def mark_exited!(lane_process)
        now = Time.current
        lane_process.update_columns(
          status: LaneProcess::EXITED,
          ended_at: lane_process.ended_at || now,
          last_seen_at: now,
          updated_at: now,
        )
      end
  end
end
