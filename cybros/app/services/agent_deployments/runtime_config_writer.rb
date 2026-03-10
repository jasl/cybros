require "fileutils"
require "json"

module AgentDeployments
  class RuntimeConfigWriter
    def initialize(deployment:)
      @deployment = deployment
    end

    def write!
      target_path = runtime_config_path
      FileUtils.mkdir_p(File.dirname(target_path))

      temp_path = "#{target_path}.tmp-#{SecureRandom.hex(6)}"
      File.write(temp_path, JSON.pretty_generate(runtime_payload))
      FileUtils.mv(temp_path, target_path)

      target_path
    ensure
      FileUtils.rm_f(temp_path) if defined?(temp_path) && temp_path.present? && File.exist?(temp_path)
    end

    def runtime_config_path
      configured_path = deployment.transport_config.fetch("runtime_config_path", "").to_s
      return configured_path if configured_path.present?

      runtime_root.join(".cybros", "agent_deployments", deployment.id.to_s, "runtime.json").to_s
    end

    private

      attr_reader :deployment

      def runtime_root
        RuntimeSetting.instance_agent_workspace_root_path
      end

      def runtime_payload
        {
          "generated_at" => Time.current.change(usec: 0).iso8601,
          "protocol_version" => deployment.protocol_version,
          "agent_program" => {
            "id" => deployment.agent_program_id,
            "name" => deployment.agent_program.name,
            "source_kind" => deployment.agent_program.source_kind,
            "bundled_agent_key" => deployment.agent_program.bundled_agent_key,
            "source_root" => deployment.agent_program.absolute_local_path.to_s,
          }.compact,
          "deployment" => {
            "id" => deployment.id,
            "contract_fingerprint" => deployment.contract_fingerprint,
            "deployment_fingerprint" => deployment.deployment_fingerprint,
            "deployment_bearer_secret_ref" => deployment.deployment_bearer_secret_ref,
          },
          "transport" => {
            "kind" => deployment.transport_kind,
            "host" => deployment.transport_config["host"],
            "port" => deployment.transport_config["port"],
            "rpc_path" => deployment.transport_config["rpc_path"],
            "endpoint_url" => deployment.endpoint_url,
          },
        }
      end
  end
end
