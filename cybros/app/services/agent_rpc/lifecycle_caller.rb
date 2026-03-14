module AgentRPC
  class LifecycleCaller
    def self.call!(
      deployment:,
      conversation:,
      scope_type:,
      scope_id:,
      method_name:,
      invocation_id:,
      request_payload:,
      allowed_callback_methods:,
      result_validator: nil,
      rpc_client_factory: nil
    )
      new(
        deployment: deployment,
        conversation: conversation,
        scope_type: scope_type,
        scope_id: scope_id,
        method_name: method_name,
        invocation_id: invocation_id,
        request_payload: request_payload,
        allowed_callback_methods: allowed_callback_methods,
        result_validator: result_validator,
        rpc_client_factory: rpc_client_factory,
      ).call!
    end

    def initialize(
      deployment:,
      conversation:,
      scope_type:,
      scope_id:,
      method_name:,
      invocation_id:,
      request_payload:,
      allowed_callback_methods:,
      result_validator:,
      rpc_client_factory:
    )
      @deployment = deployment
      @conversation = conversation
      @scope_type = scope_type
      @scope_id = scope_id
      @method_name = method_name
      @invocation_id = invocation_id
      @request_payload = request_payload.is_a?(Hash) ? request_payload.deep_stringify_keys : {}
      @allowed_callback_methods = Array(allowed_callback_methods)
      @result_validator = result_validator
      @rpc_client_factory = rpc_client_factory
    end

    def call!
      agent, recognized_deployment = resolve_runtime_binding!
      started =
        InvocationStore.start_or_replay!(
          agent: agent,
          recognized_deployment: recognized_deployment,
          deployment: deployment,
          conversation: conversation,
          scope_type: scope_type,
          scope_id: scope_id,
          method_name: method_name,
          invocation_id: invocation_id,
          request_payload: request_payload,
        )
      invocation = started.fetch(:invocation)

      case invocation.status
      when "succeeded"
        validate_result!(invocation: invocation, result: invocation.result_snapshot)
      when "failed"
        AgentCore::ValidationError.raise!(
          "Invocation has already failed.",
          code: "cybros.agent_rpc.invocation_failed",
          details: { agent_rpc_invocation_id: invocation.id, error_snapshot: invocation.error_snapshot },
        )
      else
        expected_recognized_deployment = invocation.recognized_deployment || recognized_deployment
        opened =
          SessionAuthorizer.open!(
            deployment: deployment,
            conversation: conversation,
            agent: agent,
            recognized_deployment: expected_recognized_deployment,
            scope_type: scope_type,
            scope_id: scope_id,
            allowed_methods: allowed_callback_methods,
          )
        session = opened.fetch(:session)
        session_bearer = opened.fetch(:session_bearer)
        session.update!(agent_rpc_invocation: invocation)
        invoke_remote!(invocation: invocation, session: session, session_bearer: session_bearer)
      end
    rescue AgentCore::ValidationError => e
      raise if !defined?(invocation) || invocation.nil?
      raise unless invocation.persisted?
      raise unless persistable_validation_failure?(invocation: invocation, error: e)

      InvocationStore.mark_failed!(
        invocation: invocation,
        error_snapshot: { "message" => e.message, "code" => e.code, "details" => e.details },
      )
      raise
    end

    private

      attr_reader :deployment, :conversation, :scope_type, :scope_id, :method_name, :invocation_id, :request_payload, :allowed_callback_methods, :result_validator, :rpc_client_factory

      def resolve_runtime_binding!
        explicit_agent = conversation&.agent
        runtime_record =
          case scope_type.to_s
          when "run_draft"
            RunDraft.find_by(id: scope_id)
          when "conversation_run"
            ConversationRun.find_by(id: scope_id)
          end
        explicit_agent = runtime_record&.agent || explicit_agent

        recognized_deployment = runtime_record&.recognized_deployment
        agent = explicit_agent || (deployment if deployment.is_a?(Agent)) || recognized_deployment&.agent
        if recognized_deployment.blank? && agent.present?
          ensure_deployment_binding_active!
          recognized_deployment =
            SessionAuthorizer.resolve_initialized_runtime!(
              deployment: deployment,
              agent: agent,
            ).fetch(:recognized_deployment)
        end

        return [agent, recognized_deployment] if agent.present? && recognized_deployment.present?

        AgentCore::ValidationError.raise!(
          "Runtime binding is missing the selected agent deployment snapshot.",
          code: "cybros.agent_rpc.runtime_binding_missing",
          details: { scope_type: scope_type, scope_id: scope_id, agent_id: deployment.id },
        )
      end

      def invoke_remote!(invocation:, session:, session_bearer:)
        result = rpc_client(session: session, session_bearer: session_bearer, invocation: invocation).call(method_name, remote_params(session_bearer))
        validated_result = validate_result!(invocation: invocation, result: result, session: session)
        InvocationStore.mark_succeeded!(invocation: invocation, result_snapshot: result, session: session)
        close_session!(session, invocation: invocation)
        validated_result
      rescue LostReplyError => e
        InvocationStore.mark_reply_unknown!(
          invocation: invocation,
          error_snapshot: { "message" => e.message, "kind" => "lost_reply" },
          session: session,
        )
        close_session!(session, invocation: invocation)
        AgentCore::ValidationError.raise!(
          "Invocation reply was lost.",
          code: "cybros.agent_rpc.reply_unknown",
          details: { agent_rpc_invocation_id: invocation.id, method_name: method_name },
        )
      rescue AgentCore::ValidationError
        close_session!(session, invocation: invocation)
        raise
      rescue StandardError => e
        InvocationStore.mark_failed!(
          invocation: invocation,
          error_snapshot: { "message" => e.message, "class" => e.class.name },
          session: session,
        )
        close_session!(session, invocation: invocation)
        raise
      end

      def validate_result!(invocation:, result:, session: nil)
        return result if result_validator.nil?

        result_validator.call(result)
      rescue AgentCore::ValidationError => e
        InvocationStore.mark_failed!(
          invocation: invocation,
          error_snapshot: { "message" => e.message, "code" => e.code, "details" => e.details },
          result_snapshot: result,
          session: session,
        )
        raise
      end

      def close_session!(session, invocation: nil)
        attributes = { status: "closed" }
        attributes[:agent_rpc_invocation] = invocation if invocation.present?
        session.update!(attributes)
      end

      def rpc_client(session:, session_bearer:, invocation:)
        return ::Agents::RPCClient.new(agent: invocation.agent, recognized_deployment: invocation.recognized_deployment, deployment: deployment) if rpc_client_factory.nil?

        rpc_client_factory.call(
          deployment: deployment,
          session: session,
          session_bearer: session_bearer,
          invocation: invocation,
        )
      end

      def remote_params(session_bearer)
        payload = request_payload.merge("invocation_id" => invocation_id)
        return payload if allowed_callback_methods.empty?

        payload.merge(
          "callback_session" => {
            "endpoint" => AgentRPC::CallbackEndpoint.url(scope_type: scope_type, scope_id: scope_id),
            "bearer" => session_bearer,
            "scope_type" => scope_type,
            "scope_id" => scope_id,
            "allowed_methods" => allowed_callback_methods.map(&:to_s),
          },
        )
      end

      def persistable_validation_failure?(invocation:, error:)
        return true if invocation.status == "pending"

        invocation.status == "reply_unknown" && error.code == "cybros.agent_rpc.recognized_deployment_drift"
      end

      def ensure_deployment_binding_active!
        active = deployment.status == "active" && deployment.health_status == "healthy" && deployment.activated_at.present?
        return if active

        AgentCore::ValidationError.raise!(
          "Pinned deployment binding is no longer active and healthy.",
          code: "cybros.agent_rpc.deployment_activation_drift",
          details: { agent_id: deployment.id, status: deployment.status, health_status: deployment.health_status },
        )
      end

      def recognized_deployment_for(deployment, agent: nil)
        resolved_agent = agent || (deployment if deployment.is_a?(Agent))
        resolved_agent ||= deployment.respond_to?(:agent) ? deployment.agent : nil
        return nil if resolved_agent.blank?

        scope = RecognizedDeployment.where(agent_id: resolved_agent.id)
        scope = scope.where(deployment_fingerprint: deployment.deployment_fingerprint) if deployment.respond_to?(:deployment_fingerprint)
        scope = scope.where(protocol_version: deployment.protocol_version) if deployment.respond_to?(:protocol_version)
        scope.order(Arel.sql("retired_at IS NULL DESC"), updated_at: :desc).first
      end
  end
end
