require "fileutils"
require "pathname"
require "socket"

module LaneProcesses
  class Launcher
    STARTUP_GRACE_SECONDS = 0.2

    def self.call!(conversation:, lane:, owner_turn: nil, started_by_type:, command:, cwd: nil, env: nil, title: nil, port_hints: nil)
      new(
        conversation: conversation,
        lane: lane,
        owner_turn: owner_turn,
        started_by_type: started_by_type,
        command: command,
        cwd: cwd,
        env: env,
        title: title,
        port_hints: port_hints,
      ).call!
    end

    def initialize(conversation:, lane:, owner_turn:, started_by_type:, command:, cwd:, env:, title:, port_hints:)
      @conversation = conversation
      @lane = lane
      @owner_turn = owner_turn
      @started_by_type = started_by_type
      @command = command.to_s
      @cwd = cwd
      @env = env
      @title = title
      @port_hints = port_hints
    end

    def call!
      validate_command!

      workspace_payload = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      lane_path = Conversations::WorkspaceInitializer.materialize_lane_directory!(conversation: conversation, lane_id: lane.id)
      resolved_cwd = resolve_cwd!(workspace_payload: workspace_payload)
      normalized_port_hints = LaneProcess.normalize_port_hints(port_hints)
      validate_port_availability!(normalized_port_hints)
      launch_started_at = Time.current

      lane_process =
        LaneProcess.create!(
          conversation: conversation,
          lane: lane,
          owner_turn: owner_turn,
          started_by_type: started_by_type,
          status: LaneProcess::STARTING,
          title: title.to_s.strip.presence || command.strip,
          command: command.strip,
          cwd: resolved_cwd.to_s,
          port_hints: normalized_port_hints,
          started_at: launch_started_at,
          last_seen_at: launch_started_at,
        )

      log_path = build_log_path(lane_path: lane_path, lane_process: lane_process)
      env_payload = normalize_env(env)
      log_file = File.open(log_path, "a")

      pid =
        Process.spawn(
          env_payload,
          "/bin/sh",
          "-lc",
          command,
          chdir: resolved_cwd.to_s,
          out: log_file,
          err: log_file,
          pgroup: true,
        )

      pgid = Process.getpgid(pid)
      start_signature = LaneProcesses::ProcessRuntime.start_signature(pid)
      sleep STARTUP_GRACE_SECONDS

      if LaneProcesses::ProcessRuntime.alive?(pid)
        Process.detach(pid)
        now = Time.current
        lane_process.update!(
          status: LaneProcess::RUNNING,
          pid: pid,
          pgid: pgid,
          log_path: log_path.to_s,
          last_seen_at: now,
          summary_json: {
            "cwd" => resolved_cwd.to_s,
            "startup_grace_seconds" => STARTUP_GRACE_SECONDS,
            "process_start_signature" => start_signature,
          },
        )
      else
        _reaped_pid, status = Process.wait2(pid)
        lane_process.update!(
          status: LaneProcess::FAILED,
          pid: pid,
          pgid: pgid,
          log_path: log_path.to_s,
          exit_code: status.exitstatus,
          last_seen_at: Time.current,
          ended_at: Time.current,
          summary_json: {
            "cwd" => resolved_cwd.to_s,
            "launch_error" => "process exited during startup grace window",
          },
        )

        AgentCore::ValidationError.raise!(
          "Background process exited immediately.",
          code: "cybros.lane_processes.start_background_process.exited_during_startup",
          details: {
            lane_process_id: lane_process.id,
            exit_code: status.exitstatus,
          },
        )
      end

      lane_process
    rescue AgentCore::ValidationError
      raise
    rescue => e
      cleanup_spawned_process!(pid: defined?(pid) ? pid : nil, pgid: defined?(pgid) ? pgid : nil)

      if defined?(lane_process) && lane_process.present?
        lane_process.update!(
          status: LaneProcess::FAILED,
          log_path: log_path.to_s.presence || lane_process.log_path,
          last_seen_at: Time.current,
          ended_at: Time.current,
          summary_json: lane_process.summary_json.merge("launch_error" => "#{e.class}: #{e.message}"),
        )
      end

      AgentCore::ValidationError.raise!(
        "Background process failed to start.",
        code: "cybros.lane_processes.start_background_process.launch_failed",
        details: {
          error_class: e.class.name,
          message: e.message.to_s,
        },
      )
    ensure
      log_file&.close unless log_file&.closed?
    end

    private

      attr_reader :conversation, :lane, :owner_turn, :started_by_type, :command, :cwd, :env, :title, :port_hints

      def validate_command!
        return if command.strip.present?

        AgentCore::ValidationError.raise!(
          "command is required",
          code: "cybros.lane_processes.start_background_process.command_required",
        )
      end

      def resolve_cwd!(workspace_payload:)
        root = Pathname.new(workspace_payload.fetch(:conversation_path)).expand_path
        requested = cwd.to_s.strip
        return root if requested.blank?

        path =
          if requested.start_with?("/")
            Pathname.new(requested).expand_path
          else
            root.join(requested).expand_path
          end

        ensure_within_workspace!(path, root)
        AgentCore::ValidationError.raise!(
          "cwd must exist",
          code: "cybros.lane_processes.start_background_process.cwd_missing",
          details: { cwd: path.to_s },
        ) unless path.directory?

        path
      end

      def ensure_within_workspace!(path, root)
        normalized = path.to_s
        workspace_root = root.to_s
        return if normalized == workspace_root || normalized.start_with?(workspace_root + File::SEPARATOR)

        AgentCore::ValidationError.raise!(
          "cwd must stay inside the conversation workspace",
          code: "cybros.lane_processes.start_background_process.cwd_outside_workspace",
          details: {
            cwd: normalized,
            workspace_root: workspace_root,
          },
        )
      end

      def normalize_env(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, raw), out|
          normalized_key = key.to_s.strip
          next if normalized_key.empty?

          out[normalized_key] = raw.to_s
        end
      end

      def build_log_path(lane_path:, lane_process:)
        process_dir = Pathname.new(lane_path).join(".cybros", "processes", lane_process.id.to_s)
        FileUtils.mkdir_p(process_dir)
        process_dir.join("combined.log")
      end

      def validate_port_availability!(normalized_port_hints)
        return if normalized_port_hints.empty?

        LaneProcesses::Reconciler.call!(conversation: conversation)

        conflicting_processes =
          conversation.lane_processes.active.select do |lane_process|
            (lane_process.port_hints & normalized_port_hints).any?
          end

        if conflicting_processes.any?
          AgentCore::ValidationError.raise!(
            "A tracked background process already occupies one of the requested ports.",
            code: "cybros.lane_processes.start_background_process.port_conflict",
            details: {
              occupied_ports: conflicting_processes.flat_map(&:port_hints).uniq.sort,
              lane_process_ids: conflicting_processes.map(&:id),
            },
          )
        end

        occupied_ports = normalized_port_hints.select { |port| port_occupied?(port) }
        return if occupied_ports.empty?

        AgentCore::ValidationError.raise!(
          "A local process already occupies one of the requested ports.",
          code: "cybros.lane_processes.start_background_process.port_conflict",
          details: { occupied_ports: occupied_ports },
        )
      end

      def port_occupied?(port)
        server = TCPServer.new("127.0.0.1", port)
        server.close
        false
      rescue Errno::EADDRINUSE
        true
      rescue Errno::EACCES
        true
      end

      def cleanup_spawned_process!(pid:, pgid:)
        return if pid.blank?

        LaneProcesses::ProcessRuntime.signal_group_or_pid(pgid: pgid || pid, pid: pid, signal: "TERM")
        sleep 0.1
        LaneProcesses::ProcessRuntime.signal_group_or_pid(pgid: pgid || pid, pid: pid, signal: "KILL") if LaneProcesses::ProcessRuntime.alive?(pid)
        reap_pid(pid)
      end

      def reap_pid(pid)
        10.times do
          Process.waitpid(pid, Process::WNOHANG)
          break unless LaneProcesses::ProcessRuntime.alive?(pid)

          sleep 0.05
        rescue Errno::ECHILD
          break
        end
      end
  end
end
