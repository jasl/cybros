module AgentRpc
  class CallbackDispatcher
    MUTATING_METHODS = %w[
      conversation.settings.update
      conversation.config.update
      conversation.kv.set
      conversation.kv.delete
      execution_target.propose
    ].freeze

    def self.call!(bearer:, method_name:, scope_type:, scope_id:, payload:)
      session =
        SessionAuthorizer.authorize_callback!(
          bearer: bearer,
          method_name: method_name,
          scope_type: scope_type,
          scope_id: scope_id,
        )

      new(session: session, method_name: method_name, payload: payload).call!
    end

    def initialize(session:, method_name:, payload:)
      @session = session
      @method_name = method_name.to_s
      @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    end

    def call!
      case method_name
      when "conversation.settings.get"
        AgentRpc::KernelServices::ConversationSettings.get(draft: draft)
      when "conversation.settings.update"
        apply_mutation! { AgentRpc::KernelServices::ConversationSettings.update!(draft: draft, patch: payload.fetch("patch", {})) }
      when "conversation.config.get"
        AgentRpc::KernelServices::ConversationConfig.get(draft: draft)
      when "conversation.config.update"
        apply_mutation! { AgentRpc::KernelServices::ConversationConfig.update!(draft: draft, patch: payload.fetch("patch", {})) }
      when "conversation.kv.get"
        AgentRpc::KernelServices::ConversationKV.get(draft: draft, key: payload.fetch("key"))
      when "conversation.kv.set"
        apply_mutation! { AgentRpc::KernelServices::ConversationKV.set!(draft: draft, key: payload.fetch("key"), value: payload["value"]) }
      when "conversation.kv.delete"
        apply_mutation! { AgentRpc::KernelServices::ConversationKV.delete!(draft: draft, key: payload.fetch("key")) }
      when "conversation.kv.list"
        AgentRpc::KernelServices::ConversationKV.list(draft: draft, prefix: payload["prefix"])
      when "execution_target.list"
        AgentRpc::KernelServices::ExecutionTargets.list(entrypoint: draft.conversation, draft: draft)
      when "execution_target.get"
        AgentRpc::KernelServices::ExecutionTargets.get(
          entrypoint: draft.conversation,
          draft: draft,
          execution_target_id: payload.fetch("execution_target_id"),
        )
      when "execution_target.propose"
        apply_mutation! { AgentRpc::KernelServices::ExecutionTargets.propose!(draft: draft, execution_target_id: payload.fetch("execution_target_id")) }
      else
        AgentCore::ValidationError.raise!(
          "Callback method is not implemented.",
          code: "cybros.agent_rpc.callback_method_unknown",
          details: { method_name: method_name },
        )
      end
    end

    private

      attr_reader :session, :method_name, :payload

      def apply_mutation!
        operation_id = payload.fetch("operation_id").to_s
        invocation = session.agent_rpc_invocation || missing_invocation!
        existing =
          AgentRpcOperationReceipt.find_by(
            agent_rpc_invocation: invocation,
            operation_id: operation_id,
          )

        if existing.present?
          AgentRpc::OperationReceiptStore.record_or_replay!(
            invocation: invocation,
            session: session,
            operation_id: operation_id,
            method_name: method_name,
            payload: payload,
            status: existing.status,
            response_snapshot: existing.response_snapshot,
          )
          return existing.response_snapshot
        end

        response_snapshot = yield
        AgentRpc::OperationReceiptStore.record_or_replay!(
          invocation: invocation,
          session: session,
          operation_id: operation_id,
          method_name: method_name,
          payload: payload,
          status: "applied",
          response_snapshot: response_snapshot,
        )
        response_snapshot
      end

      def draft
        @draft ||=
          begin
            unless session.scope_type == "run_draft"
              AgentCore::ValidationError.raise!(
                "Callback scope type is not supported.",
                code: "cybros.agent_rpc.callback_scope_unsupported",
                details: { scope_type: session.scope_type, scope_id: session.scope_id },
              )
            end

            RunDraft.find(session.scope_id)
          end
      end

      def missing_invocation!
        AgentCore::ValidationError.raise!(
          "Callback session is not bound to an invocation.",
          code: "cybros.agent_rpc.callback_invocation_missing",
          details: { agent_rpc_session_id: session.id },
        )
      end
  end
end
