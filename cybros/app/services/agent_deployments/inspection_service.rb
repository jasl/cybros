module AgentDeployments
  class InspectionService
    def initialize(deployment:)
      @deployment = deployment
      @client = RpcClient.new(deployment: deployment)
    end

    def inspect!
      initialize_result = client.call("initialize")
      identity = normalize_hash(initialize_result["identity"])
      protocol_version = negotiated_protocol_version!(identity)
      validate_identity!(identity)

      describe_result = client.call("agent.describe")
      health_result = client.call("agent.health")
      schemas_result = client.call("agent.schemas.get")

      deployment.update!(
        protocol_version: protocol_version,
        agent_sdk_version: identity["agent_sdk_version"],
        supported_methods: Array(identity["supported_methods"]).map(&:to_s),
        manifest_snapshot: {
          "name" => describe_result["name"],
          "description" => describe_result["description"],
          "identity" => identity,
        }.compact,
        schema_snapshot: normalize_hash(schemas_result),
        capability_snapshot: { "supported_methods" => Array(identity["supported_methods"]).map(&:to_s) },
        inspection_details: {
          "initialize" => normalize_hash(initialize_result),
          "describe" => normalize_hash(describe_result),
          "health" => normalize_hash(health_result),
          "schemas" => normalize_hash(schemas_result),
          "identity" => identity,
        },
        health_status: health_status_for(health_result),
        last_inspected_at: Time.current,
        last_health_checked_at: Time.current,
      )
    rescue Error => e
      deployment.update!(
        status: "inactive",
        health_status: "unhealthy",
        inspection_details: deployment.inspection_details.merge("error" => e.message),
        last_inspected_at: Time.current,
      )
      raise
    end

    private

      attr_reader :deployment, :client

      def validate_identity!(identity)
        expected_program_key = deployment.agent_program.manifest_snapshot["agent_program_key"].to_s.presence
        if expected_program_key.present? && identity["agent_program_key"].to_s != expected_program_key
          raise IdentityMismatchError, "deployment identity mismatch: program key"
        end

        if identity["deployment_fingerprint"].to_s != deployment.deployment_fingerprint.to_s
          raise IdentityMismatchError, "deployment identity mismatch: fingerprint"
        end
      end

      def negotiated_protocol_version!(identity)
        protocol_version = identity["protocol_version"].to_s.presence
        return protocol_version if protocol_version.present?

        raise InspectionError, "deployment identity missing protocol_version"
      end

      def health_status_for(result)
        if result["healthy"] == true
          "healthy"
        else
          result["status"].to_s.presence || "unhealthy"
        end
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end
  end
end
