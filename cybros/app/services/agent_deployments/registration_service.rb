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
      AgentDeployment.create!(
        agent_program: agent_program,
        transport_kind: transport_kind,
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        contract_fingerprint: agent_program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
        health_status: "unknown",
        protocol_version: SUPPORTED_PROTOCOL_VERSION,
        supported_methods: REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end

    private

      attr_reader :agent_program, :transport_kind, :endpoint_url, :deployment_bearer_secret_ref, :deployment_fingerprint
  end
end
