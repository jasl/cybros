require "optparse"
require "rbconfig"
require "set"

module Cybros
  module ManagedAgentDeployments
    class Supervisor
      POLL_INTERVAL_S = 1

      ManagedProcess = Struct.new(:pid, :signature, :ready, keyword_init: true)

      def initialize(poll_interval_s: POLL_INTERVAL_S, out: $stdout, err: $stderr)
        @poll_interval_s = poll_interval_s
        @out = out
        @err = err
        @processes = {}
        @failed_deployments = Set.new
        @stopping = false
      end

      def run
        trap_signals!

        until stopping?
          tick!
          sleep poll_interval_s
        end
      ensure
        shutdown_children!
      end

      def tick!
        reap_children!
        reconcile!
      end

      def stop!
        @stopping = true
      end

      def shutdown!
        stop!
        send(:shutdown_children!)
      end

      private

        attr_reader :poll_interval_s, :out, :err

        def stopping?
          @stopping == true
        end

        def trap_signals!
          Signal.trap("INT") { stop! }
          Signal.trap("TERM") { stop! }
        end

        def reconcile!
          desired = desired_deployments.index_by(&:id)
          stop_removed_processes!(desired)

          desired.each_value do |deployment|
            ensure_process!(deployment)
            reconcile_activation!(deployment)
          end
        end

        def desired_deployments
          AgentDeployment.includes(:agent_program).order(:created_at).select do |deployment|
            managed_local_deployment?(deployment)
          end
        end

        def managed_local_deployment?(deployment)
          return false unless deployment.transport_kind.to_s == "http_jsonrpc"
          return false if deployment.runtime_config_path.blank?

          server_command_for(deployment).file?
        rescue ArgumentError, Errno::ENOENT
          false
        end

        def stop_removed_processes!(desired)
          @processes.each do |deployment_id, state|
            deployment = desired[deployment_id]
            if deployment.nil?
              terminate_process(state.pid)
              @processes.delete(deployment_id)
              next
            end

            next if state.signature == signature_for(deployment)

            terminate_process(state.pid)
            @processes.delete(deployment_id)
          end
        end

        def ensure_process!(deployment)
          state = @processes[deployment.id]
          return if state.present?
          return if @failed_deployments.include?(deployment.id)

          pid = Process.spawn(*spawn_command_for(deployment), out: out, err: err)
          @processes[deployment.id] = ManagedProcess.new(pid: pid, signature: signature_for(deployment), ready: false)
        rescue StandardError => e
          mark_launch_failure!(deployment, error_message: e.message)
        end

        def reconcile_activation!(deployment)
          state = @processes[deployment.id]
          return if state.nil?
          return if state.ready && deployment.status == "active" && deployment.health_status == "healthy"

          AgentDeployments::InspectionService.new(deployment: deployment).inspect!
          AgentDeployments::ActivationService.new(deployment: deployment).activate!
          state.ready = true
        rescue AgentDeployments::ActivationError => e
          return if e.message == "deployment is not healthy"

          mark_launch_failure!(deployment, error_message: e.message)
        rescue AgentDeployments::Error
          nil
        end

        def reap_children!
          loop do
            pid, status = Process.waitpid2(-1, Process::WNOHANG)
            break if pid.nil?

            deployment_id, _state = @processes.find { |_id, managed| managed.pid == pid }
            next if deployment_id.nil?

            @processes.delete(deployment_id)
            @failed_deployments.add(deployment_id)
            mark_launch_failure!(AgentDeployment.find_by(id: deployment_id), exit_status: status.exitstatus)
          end
        rescue Errno::ECHILD
          nil
        end

        def shutdown_children!
          @processes.each_value { |state| terminate_process(state.pid) }
          @processes.clear
        end

        def terminate_process(pid)
          Process.kill("TERM", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def mark_launch_failure!(deployment, error_message: nil, exit_status: nil)
          return if deployment.nil?

          timestamp = Time.current.change(usec: 0)
          details = deployment.inspection_details.deep_dup
          details["supervisor"] = {
            "error_message" => error_message,
            "exit_status" => exit_status,
            "failed_at" => timestamp.iso8601,
          }.compact

          deployment.close_open_rpc_sessions!(at: timestamp)
          deployment.update!(
            status: "inactive",
            health_status: "unhealthy",
            deactivated_at: timestamp,
            last_health_checked_at: timestamp,
            inspection_details: details,
          )
        end

        def signature_for(deployment)
          [
            deployment.deployment_fingerprint,
            deployment.endpoint_url,
            deployment.runtime_config_path,
            deployment.agent_program.absolute_local_path.to_s,
          ].join("|")
        end

        def spawn_command_for(deployment)
          transport = deployment.transport_config
          command = [
            RbConfig.ruby,
            server_command_for(deployment).to_s,
            "--host",
            transport.fetch("host"),
            "--port",
            transport.fetch("port").to_s,
            "--source-root",
            deployment.agent_program.absolute_local_path.to_s,
            "--deployment-key",
            deployment.id,
            "--deployment-fingerprint",
            deployment.deployment_fingerprint,
          ]
          bearer = deployment.deployment_bearer_secret_ref.to_s.strip
          command += ["--bearer", bearer] if bearer.present?
          command
        end

        def server_command_for(deployment)
          deployment.agent_program.absolute_local_path.join("bin", "server")
        end
    end

    class CLI
      def self.run(argv)
        options = { poll_interval_s: Supervisor::POLL_INTERVAL_S }

        OptionParser.new do |parser|
          parser.on("--poll-interval SECONDS") { |value| options[:poll_interval_s] = Float(value) }
        end.parse!(argv)

        Supervisor.new(poll_interval_s: options[:poll_interval_s]).run
        0
      end
    end
  end
end
