require "digest"

module AgentRPC
  class SessionAuthorizer
    DEFAULT_EXPIRY = 5.minutes
    TRANSPORT_INSPECTION_ERROR = ::Agents::RPCClient::TransportError

    def self.open!(deployment:, conversation:, scope_type:, scope_id:, allowed_methods:, expires_in: DEFAULT_EXPIRY, agent: nil, recognized_deployment: nil)
      new(
        deployment: deployment,
        conversation: conversation,
        agent: agent,
        recognized_deployment: recognized_deployment,
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

    def self.resolve_initialized_runtime!(deployment:, agent:, expected_recognized_deployment: nil, session: nil)
      new(
        deployment: deployment,
        agent: agent,
        recognized_deployment: expected_recognized_deployment,
      ).send(
        :resolve_initialized_runtime!,
        deployment: deployment,
        agent: agent,
        expected_recognized_deployment: expected_recognized_deployment,
        session: session,
      )
    end

    def initialize(
      deployment: nil,
      conversation: nil,
      agent: nil,
      recognized_deployment: nil,
      scope_type: nil,
      scope_id: nil,
      allowed_methods: [],
      expires_in: DEFAULT_EXPIRY,
      bearer: nil,
      method_name: nil
    )
      @deployment = deployment
      @conversation = conversation
      @agent = agent
      @recognized_deployment = recognized_deployment
      @scope_type = scope_type.to_s
      @scope_id = scope_id.to_s
      @allowed_methods = Array(allowed_methods).map(&:to_s).reject(&:blank?).uniq
      @expires_in = expires_in
      @bearer = bearer.to_s
      @method_name = method_name.to_s
    end

    def open!
      ensure_active_binding!
      resolved_agent = resolve_agent_binding!
      initialized_runtime =
        resolve_initialized_runtime!(
          deployment: deployment,
          agent: resolved_agent,
          expected_recognized_deployment: recognized_deployment,
        )
      initialize_result = initialized_runtime.fetch(:initialize_result)
      current_recognized_deployment = initialized_runtime.fetch(:recognized_deployment)
      ensure_recognized_deployment_match!(
        expected_recognized_deployment: recognized_deployment,
        current_recognized_deployment: current_recognized_deployment,
      )
      raw_bearer = "arpc_#{SecureRandom.hex(24)}"
      session =
        AgentRPCSession.create!(
          agent: resolved_agent,
          recognized_deployment: current_recognized_deployment,
          recognized_deployment_key: current_recognized_deployment.recognized_deployment_key,
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
        recognized_deployment: current_recognized_deployment,
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

      attr_reader :deployment, :conversation, :agent, :recognized_deployment, :scope_type, :scope_id, :allowed_methods, :expires_in, :bearer, :method_name

      def initialize_client!(deployment:, agent:, expected_recognized_deployment: nil, session: nil)
        result = ::Agents::RPCClient.new(agent: agent, deployment: deployment).call("initialize")
        identity = result["identity"].is_a?(Hash) ? result["identity"].deep_stringify_keys : {}
        validate_identity!(deployment: deployment, identity: identity)
        result
      rescue AgentCore::ValidationError => e
        raise unless expected_recognized_deployment.present? && e.code == "cybros.agent_rpc.initialize_identity_mismatch"

        handle_recognized_deployment_drift!(
          deployment: deployment,
          expected_recognized_deployment: expected_recognized_deployment,
          session: session,
          details: e.details.merge("reason" => "initialize_identity_mismatch"),
        )
      rescue TRANSPORT_INSPECTION_ERROR => e
        code = e.message.to_s.include?("401") ? "cybros.agent_rpc.deployment_auth_failed" : "cybros.agent_rpc.initialize_failed"
        AgentCore::ValidationError.raise!(
          "Deployment initialize failed.",
          code: code,
          details: { agent_id: deployment&.id, message: e.message },
        )
      end

      def validate_identity!(deployment:, identity:)
        expected_agent_key =
          manifest_agent_key(agent&.manifest_snapshot).presence ||
            manifest_agent_key(deployment.manifest_snapshot).presence
        if expected_agent_key.present? && resolved_identity_agent_key(identity) != expected_agent_key
          AgentCore::ValidationError.raise!(
            "Deployment identity mismatch.",
            code: "cybros.agent_rpc.initialize_identity_mismatch",
            details: { agent_id: deployment.id, expected_agent_key: expected_agent_key },
          )
        end

        return if identity["deployment_fingerprint"].to_s == deployment.deployment_fingerprint.to_s

        AgentCore::ValidationError.raise!(
          "Deployment identity mismatch.",
          code: "cybros.agent_rpc.initialize_identity_mismatch",
          details: { agent_id: deployment.id, expected_deployment_fingerprint: deployment.deployment_fingerprint },
        )
      end

      def resolve_current_recognized_deployment!(agent:, deployment:, initialize_result:)
        Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
          agent: agent,
          deployment: deployment,
          initialize_result: initialize_result,
          capability_snapshot: deployment.capability_snapshot,
        )
      end

      def resolve_initialized_runtime!(deployment:, agent:, expected_recognized_deployment:, session: nil)
        initialize_result =
          initialize_client!(
            deployment: deployment,
            agent: agent,
            expected_recognized_deployment: expected_recognized_deployment,
            session: session,
          )
        current_recognized_deployment =
          resolve_current_recognized_deployment!(
            agent: agent,
            deployment: deployment,
            initialize_result: initialize_result,
          )

        {
          initialize_result: initialize_result,
          recognized_deployment: current_recognized_deployment,
        }
      end

      def resolve_agent_binding!
        resolved_agent =
          if recognized_deployment.present?
            recognized_deployment.agent
          elsif agent.present?
            agent
          elsif deployment.is_a?(Agent)
            deployment
          elsif (canonical_agent = canonical_agent_for(deployment)).present?
            canonical_agent
          elsif conversation&.agent.present? && (recognized = recognized_deployment_for(deployment, agent: conversation.agent)).present?
            recognized.agent
          elsif (recognized = recognized_deployment_for(deployment)).present?
            recognized.agent
          elsif conversation&.agent_id.present?
            conversation.agent
          end

        return resolved_agent if resolved_agent.present?

        AgentCore::ValidationError.raise!(
          "Pinned deployment binding is missing its agent runtime binding.",
          code: "cybros.agent_rpc.agent_binding_missing",
          details: { agent_id: deployment.id },
        )
      end

      def manifest_agent_key(payload)
        normalized = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
        normalized["agent_key"].to_s.presence
      end

      def resolved_identity_agent_key(identity)
        identity["agent_key"].to_s
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
        deployment = session.agent&.active_runtime_binding
        activation_matches =
          deployment.present? &&
          deployment.status == "active" &&
          deployment.health_status == "healthy" &&
          deployment.deployment_fingerprint == session.deployment_fingerprint &&
          deployment.activated_at&.change(usec: 0) == session.deployment_activated_at&.change(usec: 0)

        unless activation_matches
          session.update_columns(status: "closed", updated_at: Time.current)
          AgentCore::ValidationError.raise!(
            "Pinned deployment binding is no longer active and healthy.",
            code: "cybros.agent_rpc.deployment_activation_drift",
            details: {
              agent_rpc_session_id: session.id,
              recognized_deployment_id: session.recognized_deployment_id,
              status: deployment&.status,
              health_status: deployment&.health_status,
            },
          )
        end

        initialized_runtime =
          resolve_initialized_runtime!(
            deployment: deployment,
            agent: session.agent,
            expected_recognized_deployment: session.recognized_deployment,
            session: session,
          )
        current_recognized_deployment = initialized_runtime.fetch(:recognized_deployment)
        ensure_recognized_deployment_match!(
          expected_recognized_deployment: session.recognized_deployment,
          current_recognized_deployment: current_recognized_deployment,
          session: session,
        )
      end

      def ensure_recognized_deployment_match!(expected_recognized_deployment:, current_recognized_deployment:, session: nil)
        return if expected_recognized_deployment.blank?
        return if expected_recognized_deployment.recognized_deployment_key.to_s == current_recognized_deployment.recognized_deployment_key.to_s

        handle_recognized_deployment_drift!(
          deployment: deployment_for(expected_recognized_deployment: expected_recognized_deployment, session: session),
          expected_recognized_deployment: expected_recognized_deployment,
          current_recognized_deployment: current_recognized_deployment,
          session: session,
        )
      end

      def deployment_for(expected_recognized_deployment:, session:)
        if session.present?
          session_deployment = session.agent&.active_runtime_binding
          return session_deployment if session_deployment.present?
        end
        return deployment if defined?(deployment) && deployment.present?

        expected_recognized_deployment.agent&.active_runtime_binding
      end

      def handle_recognized_deployment_drift!(deployment:, expected_recognized_deployment:, current_recognized_deployment: nil, session: nil, details: {})
        session&.update_columns(status: "closed", updated_at: Time.current)
        AgentCore::ValidationError.raise!(
          "Pinned runtime identity changed during turn execution.",
          code: "cybros.agent_rpc.recognized_deployment_drift",
          details: {
            agent_rpc_session_id: session&.id,
            agent_id: deployment&.id,
            expected_recognized_deployment_id: expected_recognized_deployment.id,
            expected_recognized_deployment_key: expected_recognized_deployment.recognized_deployment_key,
            current_recognized_deployment_id: current_recognized_deployment&.id,
            current_recognized_deployment_key: current_recognized_deployment&.recognized_deployment_key,
          }.merge(details),
        )
      end

      def ensure_active_binding!
        active = deployment.status == "active" && deployment.health_status == "healthy" && deployment.activated_at.present?
        return if active

        AgentCore::ValidationError.raise!(
          "Pinned deployment binding is no longer active and healthy.",
          code: "cybros.agent_rpc.deployment_activation_drift",
          details: { agent_id: deployment.id, status: deployment.status, health_status: deployment.health_status },
        )
      end

      def bearer_digest(raw_bearer)
        Digest::SHA256.hexdigest(raw_bearer.to_s)
      end

      def recognized_deployment_for(deployment, agent: nil)
        resolved_agent = agent || canonical_agent_for(deployment)
        return nil if resolved_agent.blank?

        scope = RecognizedDeployment.where(agent_id: resolved_agent.id)
        scope = scope.where(deployment_fingerprint: deployment.deployment_fingerprint) if deployment.respond_to?(:deployment_fingerprint)
        scope = scope.where(protocol_version: deployment.protocol_version) if deployment.respond_to?(:protocol_version)
        scope.order(Arel.sql("retired_at IS NULL DESC"), updated_at: :desc).first
      end

      def canonical_agent_for(deployment)
        return deployment if deployment.is_a?(Agent)
        return deployment.agent if deployment.respond_to?(:agent)

        nil
      end
  end
end
