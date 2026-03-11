module RunDrafts
  class ConversationTurnPlanningService
    PREPARED_STATUS = "prepared".freeze
    AWAITING_APPROVAL_STATUS = "awaiting_approval".freeze
    CALLBACK_METHODS = %w[
      conversation.settings.get
      conversation.settings.update
      conversation.config.get
      conversation.config.update
      lane.kv.get
      lane.kv.set
      lane.kv.delete
      lane.kv.list
      lane.kv.snapshot
      lane.prompt_buffer.put
      lane.prompt_buffer.get
      lane.prompt_buffer.list
      lane.prompt_buffer.delete
      lane.prompt_buffer.clear
      lane.prompt_buffer.snapshot
      lane.prompt_buffer.render
      tokens.estimate_text
      tokens.estimate_messages
      execution_target.list
      execution_target.get
      execution_target.propose
    ].freeze

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
      response =
        AgentRPC::LifecycleCaller.call!(
          deployment: draft.agent_deployment,
          conversation: conversation,
          scope_type: "run_draft",
          scope_id: draft.id,
          method_name: "turn.prepare",
          invocation_id: draft.prepare_invocation_id,
          request_payload: prepare_params(draft),
          allowed_callback_methods: CALLBACK_METHODS,
        )

      draft.with_lock do
        draft.reload
        draft.prepared_plan = normalize_hash(response["prepared_plan"])
        draft.approval_state =
          effective_approval_state(
            draft_approval_state: draft.approval_state,
            response_approval_state: response["approval_state"],
          )
        draft.status = approval_required?(draft.approval_state) ? AWAITING_APPROVAL_STATUS : PREPARED_STATUS
        draft.save!
      end

      enqueue_expiry!(draft) if draft.status == AWAITING_APPROVAL_STATUS

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
          agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint.presence || conversation.agent_program.config_schema_fingerprint,
          prepare_invocation_id: SecureRandom.uuid,
          prepared_plan: {},
          staged_public_settings_patch: {},
          staged_agent_config_patch: {},
          staged_kv_ops: [],
          staged_prompt_buffer_ops: [],
          approval_state: { "status" => "not_required" },
          expires_at: 30.minutes.from_now.change(usec: 0),
        )
      rescue ActiveRecord::RecordInvalid => e
        raise unless stale_deployment_binding_error?(e)

        missing_agent_deployment_validation_error!(program: conversation.agent_program)
      end

      def resolve_deployment!
        program = conversation.agent_program
        unless program
          AgentCore::ValidationError.raise!(
            "Conversation agent selection is required before planning a programmable run.",
            code: "cybros.run_drafts.agent_program_missing",
          )
        end

        deployment = program.active_healthy_deployment_for_published_contract
        missing_agent_deployment_validation_error!(program:) unless deployment&.activated_at.present?

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
          "agent_config" => conversation.selected_agent_config_for(draft.agent_program),
        }
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def normalize_approval_state(value)
        normalized = normalize_hash(value)
        normalized["status"] = normalized["status"].to_s.presence || "not_required"
        normalized
      end

      def effective_approval_state(draft_approval_state:, response_approval_state:)
        kernel_state = normalize_approval_state(draft_approval_state)
        return kernel_state if approval_required?(kernel_state)

        normalize_approval_state(response_approval_state)
      end

      def approval_required?(approval_state)
        status = approval_state["status"].to_s
        status.present? && !%w[not_required approved].include?(status)
      end

      def enqueue_expiry!(draft)
        return unless draft.expires_at.present?

        RunDrafts::ExpireAwaitingApprovalJob.set(wait_until: draft.expires_at).perform_later(draft.id)
      end

      def stale_deployment_binding_error?(error)
        record = error.record
        return false unless record.is_a?(RunDraft)

        record.errors[:agent_deployment].present? || record.errors[:contract_fingerprint].present?
      end

      def missing_agent_deployment_validation_error!(program:)
        AgentCore::ValidationError.raise!(
          "Selected agent has no active healthy deployment.",
          code: "cybros.run_drafts.agent_deployment_missing",
          details: { agent_program_id: program.id, published_contract_fingerprint: program.published_contract_fingerprint },
        )
      end
  end
end
