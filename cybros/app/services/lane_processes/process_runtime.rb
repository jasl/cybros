require "open3"

module LaneProcesses
  module ProcessRuntime
    module_function

    def alive?(pid)
      return false if pid.blank?

      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def start_signature(pid)
      return nil if pid.blank?

      stdout, status = Open3.capture2("/bin/ps", "-o", "lstart=", "-p", pid.to_i.to_s)
      return nil unless status.success?

      stdout.to_s.lines.first.to_s.strip.presence
    rescue StandardError
      nil
    end

    def identity_state(lane_process)
      return :missing_pid if lane_process.pid.blank?

      current_signature = start_signature(lane_process.pid)
      return :dead if current_signature.blank?

      expected_signature = expected_start_signature(lane_process)
      return :alive if expected_signature.blank? || expected_signature == current_signature

      :mismatch
    end

    def expected_start_signature(lane_process)
      lane_process.summary_json.fetch("process_start_signature", nil).to_s.presence
    end

    def signal_process_group(lane_process, signal)
      target =
        if lane_process.pgid.present?
          -lane_process.pgid.to_i
        else
          lane_process.pid.to_i
        end

      Process.kill(signal, target)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      signal_pid(lane_process.pid, signal)
    end

    def signal_pid(pid, signal)
      return if pid.blank?

      Process.kill(signal, pid.to_i)
    rescue Errno::ESRCH
      nil
    end

    def signal_group_or_pid(pgid:, pid:, signal:)
      target = pgid.present? ? -pgid.to_i : pid.to_i
      Process.kill(signal, target)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      signal_pid(pid, signal)
    end
  end
end
