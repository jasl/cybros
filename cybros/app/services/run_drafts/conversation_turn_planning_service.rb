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
      execution_target.list
      execution_target.get
      tool_surface.manifest
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
        Cybros::ProgrammableAgent::HookCaller.call!(
          deployment: draft.agent_deployment,
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

      attr_reader :conversation, :initiated_by_user, :selected_model_ref, :trigger_snapshot

      def create_draft!
        deployment = resolve_deployment!
        Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
        deployment.reload
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
        node = draft.bound_agent_node

        {
          "invocation_id" => draft.plan_invocation_id,
          "run_draft_id" => draft.id,
          "conversation_id" => conversation.id,
          "session_context" => Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h,
          "execution_context" => Cybros::ProgrammableAgent::ExecutionContext.from_conversation_step(
            conversation: conversation,
            dag_node_id: draft.trigger_snapshot["dag_node_id"],
            node: node,
          ).to_h,
          "step" => {
            "phase" => "planning",
            "run_draft_id" => draft.id,
            "dag_node_id" => draft.trigger_snapshot["dag_node_id"].to_s,
            "turn_id" => node&.turn_id,
          }.compact,
          "user_input" => trigger_snapshot["user_input"].to_s,
          "trigger_snapshot" => draft.trigger_snapshot,
          "selected_model_ref" => draft.selected_model_ref,
          "capability_snapshot" => normalize_hash(draft.agent_deployment&.capability_snapshot),
          "permission_mode" => draft.permission_mode,
          "execution_target_id" => draft.proposed_execution_target_id,
          "public_settings" => conversation.public_settings,
          "agent_config" => conversation.selected_agent_config_for(draft.agent_program),
        }
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end

      def normalize_array(value)
        Array(value).map { |entry| entry.is_a?(Hash) ? entry.deep_stringify_keys : entry }
      end

      def apply_planning_to_draft!(draft, planning)
        planning = normalize_hash(planning)
        staged_mutations = normalize_hash(planning["staged_mutations"])
        apply_execution_target_proposal!(draft: draft, payload: planning["execution_target_proposal"])
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

        snapshot_payload = normalize_hash(draft.agent_deployment&.capability_snapshot)
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

      def apply_execution_target_proposal!(draft:, payload:)
        proposal = normalize_hash(payload)
        execution_target_id = proposal["execution_target_id"].to_s.strip
        return if execution_target_id.empty?

        AgentRPC::KernelServices::ExecutionTargets.propose!(
          draft: draft,
          execution_target_id: execution_target_id,
        )
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

        record.errors[:agent_deployment].present? || record.errors[:contract_fingerprint].present?
      end

      def missing_agent_deployment_validation_error!(program:)
        AgentCore::ValidationError.raise!(
          "Selected agent has no active healthy deployment.",
          code: "cybros.run_drafts.agent_deployment_missing",
          details: { agent_program_id: program.id, published_contract_fingerprint: program.published_contract_fingerprint },
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
