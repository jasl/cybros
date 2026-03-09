require "digest"

module AgentRpc
  class InvocationStore
    def self.replay_candidate_for(scope_type:, scope_id:, method_name:, invocation_id:)
      AgentRpcInvocation.find_by(
        scope_type: scope_type.to_s,
        scope_id: scope_id.to_s,
        method: method_name.to_s,
        invocation_id: invocation_id.to_s,
      )
    end

    def self.ensure_replayable!(invocation:, deployment:, request_payload:)
      store =
        new(
          deployment: deployment,
          conversation: invocation.conversation,
          scope_type: invocation.scope_type,
          scope_id: invocation.scope_id,
          method_name: invocation.method,
          invocation_id: invocation.invocation_id,
          request_payload: request_payload,
        )
      store.send(:ensure_same_binding!, invocation)
      store.send(:ensure_same_request!, invocation)
      invocation
    end

    def self.start_or_replay!(deployment:, conversation:, scope_type:, scope_id:, method_name:, invocation_id:, request_payload:)
      new(
        deployment: deployment,
        conversation: conversation,
        scope_type: scope_type,
        scope_id: scope_id,
        method_name: method_name,
        invocation_id: invocation_id,
        request_payload: request_payload,
      ).start_or_replay!
    end

    def self.mark_succeeded!(invocation:, result_snapshot:, session: nil)
      invocation.update!(
        status: "succeeded",
        result_snapshot: normalize_hash(result_snapshot),
        error_snapshot: {},
        last_session: session,
      )
      invocation
    end

    def self.mark_failed!(invocation:, error_snapshot:, session: nil)
      invocation.update!(
        status: "failed",
        result_snapshot: {},
        error_snapshot: normalize_hash(error_snapshot),
        last_session: session,
      )
      invocation
    end

    def self.mark_reply_unknown!(invocation:, error_snapshot:, session: nil)
      invocation.update!(
        status: "reply_unknown",
        error_snapshot: normalize_hash(error_snapshot),
        last_session: session,
      )
      invocation
    end

    def self.normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def initialize(deployment:, conversation:, scope_type:, scope_id:, method_name:, invocation_id:, request_payload:)
      @deployment = deployment
      @conversation = conversation
      @scope_type = scope_type.to_s
      @scope_id = scope_id.to_s
      @method_name = method_name.to_s
      @invocation_id = invocation_id.to_s
      @request_payload = request_payload.is_a?(Hash) ? request_payload.deep_stringify_keys : {}
    end

    def start_or_replay!
      existing = replay_candidate
      if existing.present?
        ensure_same_binding!(existing)
        ensure_same_request!(existing)
        return { invocation: existing, replayed: true }
      end

      {
        invocation:
          AgentRpcInvocation.create!(
            agent_deployment: deployment,
            conversation: conversation,
            scope_type: scope_type,
            scope_id: scope_id,
            method: method_name,
            invocation_id: invocation_id,
            binding_fingerprint: deployment.deployment_fingerprint,
            deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
            request_payload_hash: payload_hash,
            status: "pending",
            result_snapshot: {},
            error_snapshot: {},
          ),
        replayed: false,
      }
    end

    private

      attr_reader :deployment, :conversation, :scope_type, :scope_id, :method_name, :invocation_id, :request_payload

      def replay_candidate
        self.class.replay_candidate_for(
          scope_type: scope_type,
          scope_id: scope_id,
          method_name: method_name,
          invocation_id: invocation_id,
        )
      end

      def ensure_same_binding!(invocation)
        same_binding =
          invocation.binding_fingerprint == deployment.deployment_fingerprint &&
            invocation.deployment_activated_at == (deployment.activated_at || invocation.deployment_activated_at)

        return if same_binding

        AgentCore::ValidationError.raise!(
          "Invocation replay binding mismatch.",
          code: "cybros.agent_rpc.invocation_binding_mismatch",
          details: {
            invocation_id: invocation.invocation_id,
            expected_binding_fingerprint: invocation.binding_fingerprint,
            actual_binding_fingerprint: deployment.deployment_fingerprint,
          },
        )
      end

      def ensure_same_request!(invocation)
        return if invocation.request_payload_hash == payload_hash

        AgentCore::ValidationError.raise!(
          "Invocation replay payload mismatch.",
          code: "cybros.agent_rpc.invocation_payload_mismatch",
          details: { invocation_id: invocation.invocation_id },
        )
      end

      def payload_hash
        @payload_hash ||= Digest::SHA256.hexdigest(JSON.generate(request_payload))
      end
  end
end
