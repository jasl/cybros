module RunDrafts
  class ConversationTurnPlanningService
    PREPARED_STATUS = "prepared".freeze
    AWAITING_APPROVAL_STATUS = "awaiting_approval".freeze

    def self.open_and_prepare!(conversation:, initiated_by_user:, selected_model_ref:, trigger_snapshot:)
      new(
        conversation: conversation,
        initiated_by_user: initiated_by_user,
        selected_model_ref: selected_model_ref,
        trigger_snapshot: trigger_snapshot,
      ).open_and_prepare!
    end

    def initialize(conversation:, initiated_by_user:, selected_model_ref:, trigger_snapshot:)
      @conversation = conversation
      @initiated_by_user = initiated_by_user
      @selected_model_ref = selected_model_ref.to_s
      @trigger_snapshot = trigger_snapshot.is_a?(Hash) ? trigger_snapshot.deep_stringify_keys : {}
    end

    def open_and_prepare!
      draft = create_draft!
      response = rpc_client_for(draft).call("turn.prepare", prepare_params(draft))

      draft.with_lock do
        draft.prepared_plan = normalize_hash(response["prepared_plan"])
        draft.staged_public_settings_patch = normalize_hash(response["staged_public_settings_patch"])
        draft.staged_agent_config_patch = normalize_hash(response["staged_agent_config_patch"])
        draft.staged_kv_ops = normalize_array(response["staged_kv_ops"])
        draft.approval_state = normalize_approval_state(response["approval_state"])
        draft.status = approval_required?(draft.approval_state) ? AWAITING_APPROVAL_STATUS : PREPARED_STATUS
        draft.save!
      end

      draft
    end

    private

      attr_reader :conversation, :initiated_by_user, :selected_model_ref, :trigger_snapshot

      def create_draft!
        deployment = resolve_deployment!
        resolved = RuntimeGovernance::DraftGovernorResolver.resolve!(entrypoint: conversation, selected_model_ref: selected_model_ref)

        RunDraft.create!(
          conversation: conversation,
          initiated_by_user: initiated_by_user,
          status: "open",
          permission_mode: resolved.fetch(:permission_mode),
          trigger_snapshot: trigger_snapshot,
          agent_program: conversation.agent_program,
          contract_fingerprint: conversation.agent_program.published_contract_fingerprint,
          agent_deployment: deployment,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at&.change(usec: 0),
          provider_credential: resolved.fetch(:provider_credential),
          proposed_execution_target: resolved.fetch(:proposed_execution_target),
          selected_model_ref: resolved.fetch(:selected_model_ref),
          runtime_governors: resolved.fetch(:runtime_governors),
          prepare_invocation_id: SecureRandom.uuid,
          prepared_plan: {},
          staged_public_settings_patch: {},
          staged_agent_config_patch: {},
          staged_kv_ops: [],
          approval_state: { "status" => "not_required" },
          expires_at: 30.minutes.from_now.change(usec: 0),
        )
      end

      def resolve_deployment!
        program = conversation.agent_program
        unless program
          AgentCore::ValidationError.raise!(
            "Conversation agent selection is required before planning a programmable run.",
            code: "cybros.run_drafts.agent_program_missing",
          )
        end

        deployment = program.active_healthy_deployment
        unless deployment&.activated_at.present?
          AgentCore::ValidationError.raise!(
            "Selected agent has no active healthy deployment.",
            code: "cybros.run_drafts.agent_deployment_missing",
            details: { agent_program_id: program.id },
          )
        end

        deployment
      end

      def prepare_params(draft)
        {
          "invocation_id" => draft.prepare_invocation_id,
          "run_draft_id" => draft.id,
          "conversation_id" => conversation.id,
          "user_input" => trigger_snapshot["user_input"].to_s,
          "trigger_snapshot" => draft.trigger_snapshot,
          "selected_model_ref" => draft.selected_model_ref,
          "permission_mode" => draft.permission_mode,
          "execution_target_id" => draft.proposed_execution_target_id,
          "public_settings" => conversation.public_settings,
          "agent_config" => conversation.selected_agent_config,
        }
      end

      def rpc_client_for(draft)
        AgentDeployments::RpcClient.new(deployment: draft.agent_deployment)
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def normalize_array(value)
        Array(value).map { |item| item.is_a?(Hash) ? item.deep_stringify_keys : item }
      end

      def normalize_approval_state(value)
        normalized = normalize_hash(value)
        normalized["status"] = normalized["status"].to_s.presence || "not_required"
        normalized
      end

      def approval_required?(approval_state)
        status = approval_state["status"].to_s
        status.present? && !%w[not_required approved].include?(status)
      end
  end
end
