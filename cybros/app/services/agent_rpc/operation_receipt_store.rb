require "digest"

module AgentRpc
  class OperationReceiptStore
    def self.record_or_replay!(invocation:, session:, operation_id:, method_name:, payload:, status:, response_snapshot:)
      new(
        invocation: invocation,
        session: session,
        operation_id: operation_id,
        method_name: method_name,
        payload: payload,
        status: status,
        response_snapshot: response_snapshot,
      ).record_or_replay!
    end

    def initialize(invocation:, session:, operation_id:, method_name:, payload:, status:, response_snapshot:)
      @invocation = invocation
      @session = session
      @operation_id = operation_id.to_s
      @method_name = method_name.to_s
      @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      @status = status.to_s
      @response_snapshot = response_snapshot.is_a?(Hash) ? response_snapshot.deep_stringify_keys : {}
    end

    def record_or_replay!
      ensure_session_binding!

      existing = AgentRpcOperationReceipt.find_by(agent_rpc_invocation: invocation, operation_id: operation_id)
      if existing.present?
        ensure_same_effect!(existing)
        return { receipt: existing, replayed: true }
      end

      {
        receipt:
          AgentRpcOperationReceipt.create!(
            agent_rpc_invocation: invocation,
            operation_id: operation_id,
            method: method_name,
            payload_hash: payload_hash,
            status: status,
            response_snapshot: response_snapshot,
          ),
        replayed: false,
      }
    end

    private

      attr_reader :invocation, :session, :operation_id, :method_name, :payload, :status, :response_snapshot

      def ensure_session_binding!
        return if session.agent_rpc_invocation_id == invocation.id

        AgentCore::ValidationError.raise!(
          "Callback session does not match the invocation.",
          code: "cybros.agent_rpc.operation_session_mismatch",
          details: { agent_rpc_session_id: session.id, agent_rpc_invocation_id: invocation.id },
        )
      end

      def ensure_same_effect!(existing)
        return if existing.method == method_name && existing.payload_hash == payload_hash

        AgentCore::ValidationError.raise!(
          "Operation replay payload mismatch.",
          code: "cybros.agent_rpc.operation_payload_mismatch",
          details: { operation_id: operation_id, agent_rpc_invocation_id: invocation.id },
        )
      end

      def payload_hash
        @payload_hash ||= Digest::SHA256.hexdigest(JSON.generate(payload))
      end
  end
end
