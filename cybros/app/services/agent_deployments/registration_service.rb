module AgentDeployments
  class RegistrationService
    def initialize(agent_program:, transport_kind:, endpoint_url:, deployment_bearer_secret_ref:, deployment_fingerprint:)
      @agent_program = agent_program
      @transport_kind = transport_kind
      @endpoint_url = endpoint_url
      @deployment_bearer_secret_ref = deployment_bearer_secret_ref
      @deployment_fingerprint = deployment_fingerprint
    end

    def register!
      AgentDeployment.transaction do
        deployment = build_deployment!

        if deployment.managed_local_http_jsonrpc?
          runtime_config_path = RuntimeConfigWriter.new(deployment: deployment).write!
          deployment.update!(transport_config: deployment.transport_config.merge("runtime_config_path" => runtime_config_path))
        end

        deployment
      end
    end

    private

      attr_reader :agent_program, :transport_kind, :endpoint_url, :deployment_bearer_secret_ref, :deployment_fingerprint

      def build_deployment!
        transport_binding = resolved_transport_binding

        AgentDeployment.create!(
          id: next_deployment_id,
          agent_program: agent_program,
          transport_kind: transport_kind,
          endpoint_url: transport_binding.fetch("endpoint_url"),
          deployment_bearer_secret_ref: deployment_bearer_secret_ref,
          contract_fingerprint: agent_program.published_contract_fingerprint,
          deployment_fingerprint: deployment_fingerprint,
          status: "inactive",
          health_status: "unknown",
          protocol_version: SUPPORTED_PROTOCOL_VERSION,
          supported_methods: REQUIRED_METHODS,
          transport_config: transport_binding.fetch("transport_config"),
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
        )
      end

      def resolved_transport_binding
        return operator_managed_transport_binding unless local_http_jsonrpc_auto_launch?

        allocation = EndpointAllocator.new.allocate!
        runtime_config_path =
          RuntimeConfigWriter.new(
            deployment: AgentDeployment.new(
              id: next_deployment_id,
              agent_program: agent_program,
              transport_kind: transport_kind,
            ),
          ).runtime_config_path

        {
          "endpoint_url" => allocation.fetch("endpoint_url"),
          "transport_config" => {
            "host" => allocation.fetch("host"),
            "port" => allocation.fetch("port"),
            "rpc_path" => allocation.fetch("rpc_path"),
            "runtime_config_path" => runtime_config_path,
          },
        }
      end

      def operator_managed_transport_binding
        {
          "endpoint_url" => endpoint_url,
          "transport_config" => {},
        }
      end

      def local_http_jsonrpc_auto_launch?
        transport_kind.to_s == "http_jsonrpc" && endpoint_url.to_s.strip.blank?
      end

      def next_deployment_id
        @next_deployment_id ||=
          AgentDeployment.with_connection do |connection|
            connection.select_value("SELECT uuidv7()")
          end
      end
  end
end
