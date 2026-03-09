module AgentDeployments
  class ActivationService
    def initialize(deployment:)
      @deployment = deployment
    end

    def activate!
      raise ActivationError, "deployment must be inspected before activation" unless inspected?
      raise ActivationError, "unsupported protocol version" unless deployment.protocol_version == SUPPORTED_PROTOCOL_VERSION
      raise ActivationError, "deployment is not healthy" unless deployment.health_status == "healthy"

      missing_methods = REQUIRED_METHODS - Array(deployment.supported_methods).map(&:to_s)
      raise ActivationError, "deployment is missing required methods" if missing_methods.any?

      identity = deployment.inspection_details.fetch("identity", {})
      if identity["deployment_fingerprint"].to_s != deployment.deployment_fingerprint.to_s
        raise ActivationError, "deployment identity mismatch"
      end

      ActiveRecord::Base.transaction do
        deployment.agent_program.agent_deployments.where(status: "active").where.not(id: deployment.id).update_all(
          status: "inactive",
          deactivated_at: Time.current,
          updated_at: Time.current,
        )

        deployment.update!(
          status: "active",
          activated_at: Time.current,
          deactivated_at: nil,
        )
      end
    end

    private

      attr_reader :deployment

      def inspected?
        deployment.last_inspected_at.present? &&
          deployment.inspection_details.is_a?(Hash) &&
          deployment.inspection_details.key?("initialize") &&
          deployment.inspection_details.key?("describe") &&
          deployment.inspection_details.key?("health") &&
          deployment.inspection_details.key?("schemas")
      end
  end
end
