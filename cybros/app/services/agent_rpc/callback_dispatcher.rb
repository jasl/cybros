module AgentRPC
  class CallbackDispatcher
    PUBLIC_STATE_MUTATION_METHODS = %w[
      conversation.settings.update
      conversation.config.update
      lane.kv.set
      lane.kv.delete
      lane.prompt_buffer.put
      lane.prompt_buffer.delete
      lane.prompt_buffer.clear
    ].freeze

    MUTATING_METHODS = %w[
      conversation.settings.update
      conversation.config.update
      lane.kv.set
      lane.kv.delete
      lane.prompt_buffer.put
      lane.prompt_buffer.delete
      lane.prompt_buffer.clear
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
        AgentRPC::KernelServices::ConversationSettings.get(draft: draft)
      when "conversation.settings.update"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::ConversationSettings.update!(draft: draft, patch: payload.fetch("patch", {}))
          end
        end
      when "conversation.config.get"
        AgentRPC::KernelServices::ConversationConfig.get(draft: draft)
      when "conversation.config.update"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::ConversationConfig.update!(draft: draft, patch: payload.fetch("patch", {}))
          end
        end
      when "lane.kv.get"
        AgentRPC::KernelServices::LaneKV.get(draft: draft, key: payload.fetch("key"))
      when "lane.kv.set"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::LaneKV.set!(draft: draft, key: payload.fetch("key"), value: payload["value"])
          end
        end
      when "lane.kv.delete"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::LaneKV.delete!(draft: draft, key: payload.fetch("key"))
          end
        end
      when "lane.kv.list"
        AgentRPC::KernelServices::LaneKV.list(draft: draft, prefix: payload["prefix"])
      when "lane.kv.snapshot"
        AgentRPC::KernelServices::LaneKV.snapshot(draft: draft)
      when "lane.prompt_buffer.put"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::LanePromptBuffer.put!(
              draft: draft,
              buffer_name: payload.fetch("buffer_name"),
              kind: payload["kind"],
              content: payload.fetch("content"),
              priority: payload["priority"],
              metadata: payload["metadata"],
            )
          end
        end
      when "lane.prompt_buffer.get"
        AgentRPC::KernelServices::LanePromptBuffer.get(draft: draft, entry_id: payload.fetch("entry_id"))
      when "lane.prompt_buffer.list"
        AgentRPC::KernelServices::LanePromptBuffer.list(draft: draft, buffer_name: payload["buffer_name"])
      when "lane.prompt_buffer.delete"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::LanePromptBuffer.delete!(draft: draft, entry_id: payload.fetch("entry_id"))
          end
        end
      when "lane.prompt_buffer.clear"
        apply_mutation! do
          apply_public_state_mutation! do
            AgentRPC::KernelServices::LanePromptBuffer.clear!(draft: draft, buffer_name: payload.fetch("buffer_name"))
          end
        end
      when "lane.prompt_buffer.snapshot"
        AgentRPC::KernelServices::LanePromptBuffer.snapshot(draft: draft, buffer_name: payload["buffer_name"])
      when "lane.prompt_buffer.render"
        AgentRPC::KernelServices::LanePromptBuffer.render(
          draft: draft,
          buffer_name: payload.fetch("buffer_name"),
          max_tokens: payload.fetch("max_tokens"),
        )
      when "tokens.estimate_text"
        AgentRPC::KernelServices::Tokens.estimate_text(draft: draft, text: payload.fetch("text"))
      when "tokens.estimate_messages"
        AgentRPC::KernelServices::Tokens.estimate_messages(draft: draft, messages: payload.fetch("messages"))
      when "execution_target.list"
        AgentRPC::KernelServices::ExecutionTargets.list(entrypoint: draft.conversation, draft: draft)
      when "execution_target.get"
        AgentRPC::KernelServices::ExecutionTargets.get(
          entrypoint: draft.conversation,
          draft: draft,
          execution_target_id: payload.fetch("execution_target_id"),
        )
      when "tool_surface.manifest"
        AgentRPC::KernelServices::ToolSurfaceManifest.call!(
          deployment: session.agent_deployment,
          payload: payload,
        )
      when "execution_target.propose"
        apply_mutation! { AgentRPC::KernelServices::ExecutionTargets.propose!(draft: draft, execution_target_id: payload.fetch("execution_target_id")) }
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
          AgentRPCOperationReceipt.find_by(
            agent_rpc_invocation: invocation,
            operation_id: operation_id,
          )

        if existing.present?
          AgentRPC::OperationReceiptStore.record_or_replay!(
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

        status, response_snapshot = normalize_mutation_effect(yield)
        AgentRPC::OperationReceiptStore.record_or_replay!(
          invocation: invocation,
          session: session,
          operation_id: operation_id,
          method_name: method_name,
          payload: payload,
          status: status,
          response_snapshot: response_snapshot,
        )
        response_snapshot
      end

      def apply_public_state_mutation!
        mutation_decision =
          RuntimeGovernance::PublicStateMutationPolicy.evaluate(
            method_name: method_name,
            permission_mode: draft.permission_mode,
          )

        case mutation_decision.fetch("decision")
        when "deny"
          ["denied", { "mutation_decision" => mutation_decision }]
        when "confirm"
          response_snapshot = normalize_response_snapshot(yield)
          stage_mutation_approval!(mutation_decision: mutation_decision)
          ["pending_confirmation", response_snapshot.merge("mutation_decision" => mutation_decision)]
        else
          response_snapshot = normalize_response_snapshot(yield)
          ["applied", response_snapshot.merge("mutation_decision" => mutation_decision)]
        end
      end

      def normalize_mutation_effect(value)
        return [value.first.to_s, normalize_response_snapshot(value.last)] if value.is_a?(Array) && value.length == 2

        ["applied", normalize_response_snapshot(value)]
      end

      def normalize_response_snapshot(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def stage_mutation_approval!(mutation_decision:)
        draft.with_lock do
          draft.reload
          next if pending_approval_status?(draft.approval_state["status"])

          draft.status = RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
          draft.approval_state = {
            "status" => "pending_confirmation",
            "reason" => "public_state_mutation",
            "method_name" => mutation_decision.fetch("method_name"),
          }
          draft.save!
        end
      end

      def pending_approval_status?(status)
        normalized = status.to_s
        normalized.present? && normalized.start_with?("pending", "awaiting")
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
