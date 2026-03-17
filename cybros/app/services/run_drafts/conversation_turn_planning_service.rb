module RunDrafts
  class ConversationTurnPlanningService
    PREPARED_STATUS = "prepared".freeze
    AWAITING_APPROVAL_STATUS = "awaiting_approval".freeze
    CALLBACK_METHODS = %w[
      conversation.settings.get
      conversation.config.get
      lane.kv.get
      lane.kv.list
      lane.kv.snapshot
      lane.prompt_buffer.get
      lane.prompt_buffer.list
      lane.prompt_buffer.snapshot
      lane.prompt_buffer.render
      tokens.estimate_text
      tokens.estimate_messages
      tool_surface.manifest
    ].freeze

    def self.open_and_prepare!(conversation:, initiated_by_user:, selected_model_ref:, permission_mode: nil, trigger_snapshot:)
      new(
        conversation: conversation,
        initiated_by_user: initiated_by_user,
        selected_model_ref: selected_model_ref,
        permission_mode: permission_mode,
        trigger_snapshot: trigger_snapshot,
      ).open_and_prepare!
    end

    def initialize(conversation:, initiated_by_user:, selected_model_ref:, permission_mode: nil, trigger_snapshot:)
      @conversation = conversation
      @initiated_by_user = initiated_by_user
      @selected_model_ref = selected_model_ref.to_s
      @permission_mode = permission_mode.to_s
      @trigger_snapshot = trigger_snapshot.is_a?(Hash) ? trigger_snapshot.deep_stringify_keys : {}
    end

    def open_and_prepare!
      draft = create_draft!
      deployment = runtime_deployment_for!(draft)
      Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      response =
        Cybros::ProgrammableAgent::HookCaller.call!(
          deployment: deployment,
          conversation: conversation,
          scope_type: "run_draft",
          scope_id: draft.id,
          hook_name: "before_agent_step",
          invocation_id: draft.plan_invocation_id,
          request_payload: prepare_params(draft),
          allowed_callback_methods: CALLBACK_METHODS,
        )

      draft.with_lock do
        draft.reload
        planning = response.planning&.to_h || {}
        apply_planning_to_draft!(draft, planning)
        draft.approval_state =
          effective_approval_state(
            draft_approval_state: draft.approval_state,
            planning_approval_request: planning["approval_request"],
          )
        draft.status = approval_required?(draft.approval_state) ? AWAITING_APPROVAL_STATUS : PREPARED_STATUS
        action_result =
          Cybros::ProgrammableAgent::HookActionExecutor.execute!(
            hook_name: "before_agent_step",
            actions: response.actions,
            placeholder_node: draft.bound_agent_node,
          )

        if action_result.terminal_action&.type.to_s == "halt"
          discard_terminal_draft!(draft, terminal_action: action_result.terminal_action)
        else
          draft.save!
        end
      end

      enqueue_expiry!(draft) if draft.status == AWAITING_APPROVAL_STATUS

      draft
    end

    private

      attr_reader :conversation, :initiated_by_user, :selected_model_ref, :permission_mode, :trigger_snapshot

      def create_draft!
        agent = conversation.agent
        runtime_binding = resolve_runtime_binding!
        Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: runtime_binding)
        runtime_binding.reload
        recognized_deployment =
          AgentRPC::SessionAuthorizer.resolve_initialized_runtime!(
            deployment: runtime_binding,
            agent: agent,
          ).fetch(:recognized_deployment)
        resolved =
          RuntimeGovernance::DraftGovernorResolver.resolve!(
            entrypoint: conversation,
            selected_model_ref: selected_model_ref,
            permission_mode: permission_mode,
          )

        RunDraft.create!(
          conversation: conversation,
          initiated_by_user: initiated_by_user,
          status: "open",
          permission_mode: resolved.fetch(:permission_mode),
          trigger_snapshot: trigger_snapshot,
          agent: agent,
          recognized_deployment: recognized_deployment,
          recognized_deployment_key: recognized_deployment.recognized_deployment_key,
          contract_fingerprint: agent.published_contract_fingerprint,
          deployment_fingerprint: runtime_binding.deployment_fingerprint,
          deployment_activated_at: runtime_binding.activated_at&.change(usec: 0),
          provider_credential: resolved.fetch(:provider_credential),
          selected_model_ref: resolved.fetch(:selected_model_ref),
          runtime_governors: resolved.fetch(:runtime_governors),
          agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint.presence || agent.config_schema_fingerprint,
          prepare_invocation_id: SecureRandom.uuid,
          planning: {},
          staged_public_settings_patch: {},
          staged_agent_config_patch: {},
          staged_kv_ops: [],
          staged_prompt_buffer_ops: [],
          approval_state: { "status" => "not_required" },
          expires_at: 30.minutes.from_now.change(usec: 0),
        )
      rescue ActiveRecord::RecordInvalid => e
        raise unless stale_deployment_binding_error?(e)

        missing_agent_runtime_validation_error!(agent: agent)
      end

      def resolve_runtime_binding!
        agent = conversation.agent
        unless agent
          AgentCore::ValidationError.raise!(
            "Conversation agent selection is required before planning a programmable run.",
            code: "cybros.run_drafts.agent_missing",
          )
        end

        runtime_binding = agent.active_runtime_binding
        missing_agent_runtime_validation_error!(agent: agent) unless runtime_binding&.activated_at.present?

        runtime_binding
      end

      def prepare_params(draft)
        node = draft.bound_agent_node
        session_context = Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h
        execution_context =
          Cybros::ProgrammableAgent::ExecutionContext.from_conversation_step(
            conversation: conversation,
            dag_node_id: draft.trigger_snapshot["dag_node_id"],
            node: node,
          ).to_h

        {
          "invocation_id" => draft.plan_invocation_id,
          "run_draft_id" => draft.id,
          "conversation_id" => conversation.id,
          "session_context" => session_context,
          "execution_context" => execution_context,
          "attachment_manifest" => attachment_manifest_for_step(node: node),
          "step" => {
            "phase" => "planning",
            "run_draft_id" => draft.id,
            "dag_node_id" => draft.trigger_snapshot["dag_node_id"].to_s,
            "turn_id" => node&.turn_id,
          }.compact,
          "user_input" => trigger_snapshot["user_input"].to_s,
          "trigger_snapshot" => draft.trigger_snapshot,
          "selected_model_ref" => draft.selected_model_ref,
          "capability_snapshot" => normalize_hash(draft.recognized_deployment&.capability_snapshot),
          "permission_mode" => draft.permission_mode,
          "public_settings" => conversation.public_settings,
          "agent_config" => conversation.selected_agent_config_for(draft.agent),
        }.compact
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def attachment_manifest_for_step(node:)
        user_node = source_user_node_for_step(node: node)
        return [] if user_node.nil?

        Conversations::AttachmentManifestBuilder.build(
          conversation: conversation,
          source_message_node_id: user_node.id,
        )
      end

      def source_user_node_for_step(node:)
        turn_id = node&.turn_id || conversation.turn_id_for_node_id(draft_node_id)
        return nil if turn_id.blank?

        conversation.root_graph.nodes.active
          .where(turn_id: turn_id, node_type: Messages::UserMessage.node_type_key)
          .order(:id)
          .first
      end

      def draft_node_id
        trigger_snapshot["dag_node_id"].to_s.presence
      end

      def normalize_array(value)
        Array(value).map { |entry| entry.is_a?(Hash) ? entry.deep_stringify_keys : entry }
      end

      def apply_planning_to_draft!(draft, planning)
        planning = normalize_hash(planning)
        staged_mutations = normalize_hash(planning["staged_mutations"])
        tool_surface = normalize_tool_surface!(draft: draft, payload: planning["tool_surface"])
        planning["tool_surface"] = tool_surface if tool_surface

        draft.planning = planning
        draft.staged_public_settings_patch = normalize_hash(staged_mutations["public_settings_patch"])
        draft.staged_agent_config_patch = normalize_hash(staged_mutations["agent_config_patch"])
        draft.staged_kv_ops = normalize_array(staged_mutations["kv_ops"])
        draft.staged_prompt_buffer_ops = normalize_array(staged_mutations["prompt_buffer_ops"])
        apply_public_state_mutation_policy!(draft)
      end

      def normalize_tool_surface!(draft:, payload:)
        normalized = normalize_hash(payload)
        return nil if normalized.empty?

        snapshot_payload = normalize_hash(draft.recognized_deployment&.capability_snapshot)
        snapshot = Cybros::ProgrammableAgent::CapabilitySnapshot.restore(snapshot_payload)
        manifest =
          Cybros::ProgrammableAgent::ToolSurfaceManifest.restore(
            normalized,
            capability_registry_snapshot: snapshot,
          )

        {
          "capability_registry_snapshot_id" => snapshot.snapshot_id,
          "tool_surface_id" => manifest.tool_surface_id,
          "tool_surface_label" => manifest.tool_surface_label,
          "selected_tool_ids" => manifest.selected_tool_ids,
          "logical_tool_names" => manifest.selected_tools.map(&:logical_tool_name),
        }.compact
      end

      def normalize_approval_state(value)
        normalized = normalize_hash(value)
        normalized["status"] = normalized["status"].to_s.presence || "not_required"
        normalized
      end

      def effective_approval_state(draft_approval_state:, planning_approval_request:)
        kernel_state = normalize_approval_state(draft_approval_state)
        return kernel_state if approval_required?(kernel_state)

        normalize_approval_state(planning_approval_request)
      end

      def approval_required?(approval_state)
        status = approval_state["status"].to_s
        status.present? && !%w[not_required approved].include?(status)
      end

      def apply_public_state_mutation_policy!(draft)
        return if pending_approval_status?(draft.approval_state["status"])

        staged_mutation_methods(draft).each do |method_name|
          mutation_decision =
            RuntimeGovernance::PublicStateMutationPolicy.evaluate(
              method_name: method_name,
              permission_mode: draft.permission_mode,
            )

          case mutation_decision.fetch("decision")
          when "confirm"
            draft.approval_state = {
              "status" => "pending_confirmation",
              "reason" => "public_state_mutation",
              "method_name" => method_name,
            }
            return
          when "deny"
            AgentCore::ValidationError.raise!(
              "Planning requested a disallowed public state mutation.",
              code: "cybros.run_drafts.public_state_mutation_denied",
              details: { run_draft_id: draft.id, method_name: method_name, permission_mode: draft.permission_mode },
            )
          end
        end
      end

      def staged_mutation_methods(draft)
        methods = []
        methods << "conversation.settings.update" if draft.staged_public_settings_patch.present?
        methods << "conversation.config.update" if draft.staged_agent_config_patch.present?

        Array(draft.staged_kv_ops).each do |operation|
          case operation["op"].to_s
          when "set"
            methods << "lane.kv.set"
          when "delete"
            methods << "lane.kv.delete"
          end
        end

        Array(draft.staged_prompt_buffer_ops).each do |operation|
          case operation["op"].to_s
          when "put"
            methods << "lane.prompt_buffer.put"
          when "delete"
            methods << "lane.prompt_buffer.delete"
          when "clear"
            methods << "lane.prompt_buffer.clear"
          end
        end

        methods.uniq
      end

      def pending_approval_status?(status)
        normalized = status.to_s
        normalized.present? && normalized.start_with?("pending", "awaiting")
      end

      def enqueue_expiry!(draft)
        return unless draft.expires_at.present?

        RunDrafts::ExpireAwaitingApprovalJob.set(wait_until: draft.expires_at).perform_later(draft.id)
      end

      def stale_deployment_binding_error?(error)
        record = error.record
        return false unless record.is_a?(RunDraft)

        record.errors[:recognized_deployment].present? ||
          record.errors[:recognized_deployment_key].present? ||
          record.errors[:contract_fingerprint].present? ||
          record.errors[:deployment_fingerprint].present?
      end

      def missing_agent_runtime_validation_error!(agent:)
        agent_id = agent&.id
        contract_fingerprint = agent&.published_contract_fingerprint

        AgentCore::ValidationError.raise!(
          "Selected agent has no active healthy runtime binding.",
          code: "cybros.run_drafts.agent_runtime_missing",
          details: {
            agent_id: agent_id,
            published_contract_fingerprint: contract_fingerprint,
          },
        )
      end

      def runtime_deployment_for!(draft)
        runtime_binding = draft.agent&.active_runtime_binding

        if runtime_binding.present? &&
            runtime_binding.deployment_fingerprint.to_s == draft.deployment_fingerprint.to_s &&
            runtime_binding.activated_at&.change(usec: 0) == draft.deployment_activated_at&.change(usec: 0)
          return runtime_binding
        end

        AgentCore::ValidationError.raise!(
          "Run draft is missing its pinned runtime deployment.",
          code: "cybros.run_drafts.agent_runtime_missing",
          details: {
            run_draft_id: draft.id,
            agent_id: draft.agent_id,
            recognized_deployment_id: draft.recognized_deployment_id,
          },
        )
      end

      def discard_terminal_draft!(draft, terminal_action:)
        draft.status = "discarded"
        draft.staged_public_settings_patch = {}
        draft.staged_agent_config_patch = {}
        draft.staged_kv_ops = []
        draft.staged_prompt_buffer_ops = []
        draft.save!
        metadata = {
          "generated_by" => "programmable_agent_hook",
          "hook_name" => "before_agent_step",
          "action_type" => terminal_action.type,
        }
        metadata["message"] = terminal_action.message if terminal_action.message.present?
        draft.bound_agent_node&.stop!(
          reason: terminal_action.reason.to_s.presence || "programmable_agent_halt",
          metadata: metadata,
        )
        draft.reload
      end
  end
end
