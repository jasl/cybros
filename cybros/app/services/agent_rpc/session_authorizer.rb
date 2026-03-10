require "digest"

module AgentRPC
  class SessionAuthorizer
    DEFAULT_EXPIRY = 5.minutes

    def self.open!(deployment:, conversation:, scope_type:, scope_id:, allowed_methods:, expires_in: DEFAULT_EXPIRY)
      new(
        deployment: deployment,
        conversation: conversation,
        scope_type: scope_type,
        scope_id: scope_id,
        allowed_methods: allowed_methods,
        expires_in: expires_in,
      ).open!
    end

    def self.authorize_callback!(bearer:, method_name:, scope_type:, scope_id:)
      new(
        bearer: bearer,
        method_name: method_name,
        scope_type: scope_type,
        scope_id: scope_id,
      ).authorize_callback!
    end

    def initialize(
      deployment: nil,
      conversation: nil,
      scope_type: nil,
      scope_id: nil,
      allowed_methods: [],
      expires_in: DEFAULT_EXPIRY,
      bearer: nil,
      method_name: nil
    )
      @deployment = deployment
      @conversation = conversation
      @scope_type = scope_type.to_s
      @scope_id = scope_id.to_s
      @allowed_methods = Array(allowed_methods).map(&:to_s).reject(&:blank?).uniq
      @expires_in = expires_in
      @bearer = bearer.to_s
      @method_name = method_name.to_s
    end

    def open!
      ensure_active_binding!
      initialize_result = initialize_client!
      raw_bearer = "arpc_#{SecureRandom.hex(24)}"
      session =
        AgentRPCSession.create!(
          agent_deployment: deployment,
          agent_program: deployment.agent_program,
          conversation: conversation,
          scope_type: scope_type,
          scope_id: scope_id,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
          session_token_digest: bearer_digest(raw_bearer),
          allowed_methods: allowed_methods,
          expires_at: Time.current.advance(seconds: expires_in.to_f).change(usec: 0),
          status: "open",
        )

      {
        session: session,
        session_bearer: raw_bearer,
        initialize_result: initialize_result,
      }
    end

    def authorize_callback!
      session = find_session!
      ensure_open!(session)
      ensure_current_binding!(session)
      ensure_scope!(session)
      ensure_method_allowed!(session)
      session
    end

    private

      attr_reader :deployment, :conversation, :scope_type, :scope_id, :allowed_methods, :expires_in, :bearer, :method_name

      def initialize_client!
        result = AgentDeployments::RPCClient.new(deployment: deployment).call("initialize")
        identity = result["identity"].is_a?(Hash) ? result["identity"].deep_stringify_keys : {}
        validate_identity!(identity)
        result
      rescue AgentDeployments::InspectionError => e
        code = e.message.to_s.include?("401") ? "cybros.agent_rpc.deployment_auth_failed" : "cybros.agent_rpc.initialize_failed"
        AgentCore::ValidationError.raise!(
          "Deployment initialize failed.",
          code: code,
          details: { agent_deployment_id: deployment&.id, message: e.message },
        )
      end

      def validate_identity!(identity)
        expected_program_key = deployment.agent_program.manifest_snapshot["agent_program_key"].to_s.presence
        if expected_program_key.present? && identity["agent_program_key"].to_s != expected_program_key
          AgentCore::ValidationError.raise!(
            "Deployment identity mismatch.",
            code: "cybros.agent_rpc.initialize_identity_mismatch",
            details: { agent_deployment_id: deployment.id, expected_program_key: expected_program_key },
          )
        end

        return if identity["deployment_fingerprint"].to_s == deployment.deployment_fingerprint.to_s

        AgentCore::ValidationError.raise!(
          "Deployment identity mismatch.",
          code: "cybros.agent_rpc.initialize_identity_mismatch",
          details: { agent_deployment_id: deployment.id, expected_deployment_fingerprint: deployment.deployment_fingerprint },
        )
      end

      def find_session!
        session = AgentRPCSession.find_by(session_token_digest: bearer_digest(bearer))
        return session if session.present?

        AgentCore::ValidationError.raise!(
          "Callback session is invalid.",
          code: "cybros.agent_rpc.callback_session_invalid",
        )
      end

      def ensure_open!(session)
        unless session.status == "open"
          AgentCore::ValidationError.raise!(
            "Callback session is closed.",
            code: "cybros.agent_rpc.callback_session_closed",
            details: { agent_rpc_session_id: session.id },
          )
        end

        return unless session.expires_at.past?

        session.update_columns(status: "expired", updated_at: Time.current)
        AgentCore::ValidationError.raise!(
          "Callback session has expired.",
          code: "cybros.agent_rpc.callback_session_expired",
          details: { agent_rpc_session_id: session.id },
        )
      end

      def ensure_scope!(session)
        return if session.scope_type == scope_type && session.scope_id == scope_id

        AgentCore::ValidationError.raise!(
          "Callback session scope mismatch.",
          code: "cybros.agent_rpc.callback_scope_mismatch",
          details: { agent_rpc_session_id: session.id },
        )
      end

      def ensure_method_allowed!(session)
        return if session.allowed_methods.include?(method_name)

        AgentCore::ValidationError.raise!(
          "Callback method is not allowed for this session.",
          code: "cybros.agent_rpc.callback_method_not_allowed",
          details: { agent_rpc_session_id: session.id, method_name: method_name },
        )
      end

      def ensure_current_binding!(session)
        deployment = session.agent_deployment
        activation_matches =
          deployment.present? &&
          deployment.status == "active" &&
          deployment.health_status == "healthy" &&
          deployment.deployment_fingerprint == session.deployment_fingerprint &&
          deployment.activated_at&.change(usec: 0) == session.deployment_activated_at&.change(usec: 0)

        return if activation_matches

        session.update_columns(status: "closed", updated_at: Time.current)
        AgentCore::ValidationError.raise!(
          "Pinned deployment binding is no longer active and healthy.",
          code: "cybros.agent_rpc.deployment_activation_drift",
          details: {
            agent_rpc_session_id: session.id,
            agent_deployment_id: session.agent_deployment_id,
            status: deployment&.status,
            health_status: deployment&.health_status,
          },
        )
      end

      def ensure_active_binding!
        active = deployment.status == "active" && deployment.health_status == "healthy" && deployment.activated_at.present?
        return if active

        AgentCore::ValidationError.raise!(
          "Pinned deployment binding is no longer active and healthy.",
          code: "cybros.agent_rpc.deployment_activation_drift",
          details: { agent_deployment_id: deployment.id, status: deployment.status, health_status: deployment.health_status },
        )
      end

      def bearer_digest(raw_bearer)
        Digest::SHA256.hexdigest(raw_bearer.to_s)
      end
  end
end
