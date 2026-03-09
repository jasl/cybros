module RunDrafts
  class FinalizeService
    SNAPSHOT_VERSION = 1

    def self.finalize!(draft:, debug: {}, error: {})
      new(draft: draft, debug: debug, error: error).finalize!
    end

    def initialize(draft:, debug:, error:)
      @draft = draft
      @debug = normalize_hash(debug)
      @error = normalize_hash(error)
    end

    def finalize!
      draft.with_lock do
        ensure_finalizable!

        run = nil
        ApplicationRecord.transaction do
          apply_staged_mutations!
          run = materialize_conversation_run!
          finalize_automation_run!(conversation_run: run)
          draft.update!(
            status: "finalized",
            materialized_conversation_run: run,
            staged_public_settings_patch: {},
            staged_agent_config_patch: {},
            staged_kv_ops: [],
          )
        end

        run
      end
    rescue AgentCore::ValidationError => e
      persist_terminal_status_for!(e)
      raise
    rescue ActiveRecord::RecordInvalid => e
      raise e
    end

    private

      attr_reader :draft, :debug, :error

      def ensure_finalizable!
        ensure_not_already_finalized!
        ensure_not_terminal_status!
        ensure_not_expired!
        ensure_planning_completed!
        ensure_approval_ready!
        ensure_fresh_binding!
      end

      def ensure_not_already_finalized!
        return unless draft.status.to_s == "finalized" || draft.materialized_conversation_run_id.present?

        AgentCore::ValidationError.raise!(
          "Run draft has already been finalized.",
          code: "cybros.run_drafts.already_finalized",
          details: { run_draft_id: draft.id, conversation_run_id: draft.materialized_conversation_run_id },
        )
      end

      def ensure_not_expired!
        return if draft.expires_at.nil? || draft.expires_at.future?

        AgentCore::ValidationError.raise!(
          "Run draft has expired.",
          code: "cybros.run_drafts.expired",
          details: { run_draft_id: draft.id },
        )
      end

      def ensure_not_terminal_status!
        case draft.status.to_s
        when "stale"
          stale_validation_error!
        when "expired"
          expired_validation_error!
        when "discarded"
          AgentCore::ValidationError.raise!(
            "Run draft has already been discarded.",
            code: "cybros.run_drafts.discarded",
            details: { run_draft_id: draft.id, approval_state: draft.approval_state },
          )
        end
      end

      def ensure_approval_ready!
        return unless draft.status.to_s == "awaiting_approval"
        return if draft.approval_state["status"].to_s == "approved"

        AgentCore::ValidationError.raise!(
          "Run draft is still awaiting approval.",
          code: "cybros.run_drafts.approval_pending",
          details: { run_draft_id: draft.id, approval_state: draft.approval_state },
        )
      end

      def ensure_planning_completed!
        return if %w[prepared awaiting_approval].include?(draft.status.to_s)

        AgentCore::ValidationError.raise!(
          "Run draft has not completed planning.",
          code: "cybros.run_drafts.not_prepared",
          details: { run_draft_id: draft.id, status: draft.status },
        )
      end

      def ensure_fresh_binding!
        deployment = reload_record(draft.agent_deployment)
        target = reload_record(draft.proposed_execution_target)
        resolved = resolve_current_binding!(target: target)
        fresh =
          deployment_fresh?(deployment) &&
            target.present? &&
            RuntimeGovernance::ExecutionTargetSwitchPolicy.visible_target?(target) &&
            resolved.fetch(:permission_mode).to_s == draft.permission_mode.to_s &&
            resolved.fetch(:provider_credential).id.to_s == draft.provider_credential_id.to_s &&
            resolved.fetch(:proposed_execution_target).id.to_s == draft.proposed_execution_target_id.to_s &&
            resolved.fetch(:runtime_governors) == draft.runtime_governors

        return if fresh

        stale_validation_error!
      rescue ActiveRecord::RecordNotFound, AgentCore::ValidationError
        stale_validation_error!
      end

      def apply_staged_mutations!
        apply_public_settings_patch!
        apply_agent_config_patch!
        apply_kv_ops!
        apply_execution_target_selection!
      end

      def apply_public_settings_patch!
        return if conversation.blank?
        return if draft.staged_public_settings_patch.blank?

        conversation.public_settings = conversation.public_settings.deep_merge(draft.staged_public_settings_patch)
        conversation.save!
      end

      def apply_agent_config_patch!
        return if conversation.blank?
        return if draft.staged_agent_config_patch.blank?

        namespace = draft.agent_program.config_namespace.to_s
        agent_config = conversation.agent_config.deep_dup
        current_namespace = agent_config[namespace].is_a?(Hash) ? agent_config[namespace] : {}
        agent_config[namespace] = current_namespace.deep_merge(draft.staged_agent_config_patch)
        conversation.agent_config = agent_config
        conversation.agent_config_schema_fingerprint = draft.agent_program.config_schema_fingerprint
        conversation.save!
      end

      def apply_kv_ops!
        return if conversation.blank?

        Array(draft.staged_kv_ops).each do |operation|
          next unless operation.is_a?(Hash)

          op = operation["op"].to_s
          key = operation["key"].to_s.strip
          next if key.blank?

          case op
          when "set"
            entry = ::ConversationKVEntry.find_or_initialize_by(conversation: conversation, key: key)
            entry.value = operation["value"]
            entry.written_by_type = draft.class.name
            entry.written_by_id = draft.id
            entry.save!
          when "delete"
            ::ConversationKVEntry.where(conversation: conversation, key: key).delete_all
          end
        end
      end

      def apply_execution_target_selection!
        return if conversation.blank?
        return unless draft.proposed_execution_target.present?
        return if conversation.default_execution_target_id.to_s == draft.proposed_execution_target_id.to_s

        conversation.update!(default_execution_target: draft.proposed_execution_target)
      end

      def materialize_conversation_run!
        return nil if conversation.blank?

        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: dag_node_id!,
          state: "queued",
          queued_at: Time.current,
          snapshot_version: SNAPSHOT_VERSION,
          initiated_by_user: draft.initiated_by_user,
          effective_permission_mode: draft.permission_mode,
          agent_program: draft.agent_program,
          contract_fingerprint: draft.contract_fingerprint,
          agent_deployment: draft.agent_deployment,
          deployment_fingerprint: draft.deployment_fingerprint,
          deployment_activated_at: draft.deployment_activated_at,
          provider_credential: draft.provider_credential,
          execution_target: draft.proposed_execution_target,
          selected_model_ref: draft.selected_model_ref,
          effective_public_settings: conversation.public_settings,
          effective_agent_config: conversation.selected_agent_config_for(draft.agent_program),
          agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
          effective_policy: effective_policy_summary,
          runtime_governors: draft.runtime_governors,
          snapshot: {
            "draft" => {
              "id" => draft.id,
              "trigger_snapshot" => draft.trigger_snapshot,
              "prepared_plan" => draft.prepared_plan,
              "approval_state" => draft.approval_state,
            },
          },
          debug: debug,
          error: error,
        )
      end

      def finalize_automation_run!(conversation_run:)
        return if automation_run.blank?

        automation_run.update!(
          conversation_run: conversation_run,
          snapshot: automation_run.snapshot.deep_merge(
            "draft" => {
              "id" => draft.id,
              "trigger_snapshot" => draft.trigger_snapshot,
              "prepared_plan" => draft.prepared_plan,
              "approval_state" => draft.approval_state,
            },
            "runtime" => {
              "conversation_id" => conversation&.id,
              "conversation_run_id" => conversation_run&.id,
              "selected_model_ref" => draft.selected_model_ref,
              "permission_mode" => draft.permission_mode,
              "agent_program_id" => draft.agent_program_id,
              "contract_fingerprint" => draft.contract_fingerprint,
              "agent_deployment_id" => draft.agent_deployment_id,
              "deployment_fingerprint" => draft.deployment_fingerprint,
              "deployment_activated_at" => draft.deployment_activated_at&.iso8601,
              "provider_credential_id" => draft.provider_credential_id,
              "execution_target_id" => draft.proposed_execution_target_id,
              "runtime_governors" => draft.runtime_governors,
            }.compact,
          ),
        )
      end

      def effective_policy_summary
        Cybros::Permissions::BundleCompiler.compile(
          permission_mode: draft.permission_mode,
          tools_registry: Cybros::AgentRuntimeResolver.build_tools_registry,
        ).fetch(:summary)
      end

      def dag_node_id!
        id = draft.trigger_snapshot["dag_node_id"].to_s.strip
        return ensure_automation_agent_node!(id) if draft.automation_id.present? && conversation.present?
        return id if id.present?

        AgentCore::ValidationError.raise!(
          "Run draft is missing the queued DAG node binding.",
          code: "cybros.run_drafts.dag_node_missing",
          details: { run_draft_id: draft.id },
        )
      end

      def ensure_automation_agent_node!(requested_id)
        existing_id = requested_id.to_s.strip
        return existing_id if existing_id.present? && conversation.root_graph.nodes.exists?(id: existing_id)

        node =
          conversation.root_graph.nodes.create!(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            metadata: {
              "source" => "automation",
              "automation_id" => draft.automation_id,
              "automation_run_id" => automation_run&.id,
            }.compact,
          )
        draft.update!(trigger_snapshot: draft.trigger_snapshot.merge("dag_node_id" => node.id))
        node.id
      end

      def conversation
        return @conversation if defined?(@conversation)

        @conversation =
          if draft.conversation.present?
            draft.conversation
          elsif draft.trigger_snapshot["conversation_id"].present?
            Conversation.find_by(id: draft.trigger_snapshot["conversation_id"]) || AgentCore::ValidationError.raise!(
              "Conversation-backed finalization is missing the bound conversation.",
              code: "cybros.run_drafts.conversation_missing",
              details: { run_draft_id: draft.id, conversation_id: draft.trigger_snapshot["conversation_id"] },
            )
          end
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def reload_record(record)
        record&.reload
      end

      def deployment_fresh?(deployment)
        active_deployment = draft.agent_program&.active_healthy_deployment

        deployment.present? &&
          deployment.status == "active" &&
          deployment.health_status == "healthy" &&
          deployment.contract_fingerprint == draft.contract_fingerprint &&
          deployment.deployment_fingerprint == draft.deployment_fingerprint &&
          deployment.activated_at&.change(usec: 0) == draft.deployment_activated_at&.change(usec: 0) &&
          active_deployment&.id == deployment.id
      end

      def resolve_current_binding!(target:)
        RuntimeGovernance::DraftGovernorResolver.resolve!(
          entrypoint: runtime_entrypoint,
          selected_model_ref: draft.selected_model_ref,
          execution_target: target,
        )
      end

      def runtime_entrypoint
        return conversation if draft.conversation.present?
        return AgentRpc::KernelServices::ExecutionTargets.resolve_entrypoint_for(draft) if draft.automation_id.present?

        AgentCore::ValidationError.raise!(
          "Run draft is missing an execution entrypoint.",
          code: "cybros.run_drafts.entrypoint_missing",
          details: { run_draft_id: draft.id },
        )
      end

      def automation_run
        return @automation_run if defined?(@automation_run)

        automation_run_id = draft.trigger_snapshot["automation_run_id"].to_s.strip
        @automation_run =
          if automation_run_id.present?
            AutomationRun.find_by(id: automation_run_id)
          end
      end

      def persist_terminal_status_for!(error)
        case error.code
        when "cybros.run_drafts.expired"
          RunDrafts::DiscardService.discard!(draft: draft, status: "expired")
        when "cybros.run_drafts.stale"
          RunDrafts::DiscardService.discard!(draft: draft, status: "stale")
        end
      rescue StandardError
        nil
      end

      def expired_validation_error!
        AgentCore::ValidationError.raise!(
          "Run draft has expired.",
          code: "cybros.run_drafts.expired",
          details: { run_draft_id: draft.id },
        )
      end

      def stale_validation_error!
        AgentCore::ValidationError.raise!(
          "Run draft is stale and must be replanned.",
          code: "cybros.run_drafts.stale",
          details: {
            run_draft_id: draft.id,
            agent_deployment_id: draft.agent_deployment_id,
            deployment_fingerprint: draft.deployment_fingerprint,
          },
        )
      end
  end
end
