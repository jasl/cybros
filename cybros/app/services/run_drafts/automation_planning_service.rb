module RunDrafts
  class AutomationPlanningService
    PREPARED_STATUS = ConversationTurnPlanningService::PREPARED_STATUS
    AWAITING_APPROVAL_STATUS = ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
    CONVERSATION_CALLBACK_METHODS = ConversationTurnPlanningService::CALLBACK_METHODS
    CALLBACK_METHODS_WITHOUT_CONVERSATION = %w[
      execution_target.list
      execution_target.get
      execution_target.propose
    ].freeze

    def self.open_and_prepare!(automation_run:)
      new(automation_run: automation_run).open_and_prepare!
    end

    def initialize(automation_run:)
      @automation_run = automation_run
    end

    def open_and_prepare!
      draft = create_draft!
      response =
        AgentRpc::LifecycleCaller.call!(
          deployment: draft.agent_deployment,
          conversation: bound_conversation,
          scope_type: "run_draft",
          scope_id: draft.id,
          method_name: "turn.prepare",
          invocation_id: draft.prepare_invocation_id,
          request_payload: prepare_params(draft),
          allowed_callback_methods: callback_methods,
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

      attr_reader :automation_run

      def create_draft!
        deployment = resolve_deployment!
        resolved = RuntimeGovernance::DraftGovernorResolver.resolve!(entrypoint: automation_entrypoint, selected_model_ref: selected_model_ref)
        program = AgentProgram.find(automation_snapshot.fetch("agent_program_id"))

        RunDraft.create!(
          automation: automation_run.automation,
          initiated_by_user: automation_run.initiated_by_user,
          status: "open",
          permission_mode: resolved.fetch(:permission_mode),
          trigger_snapshot: trigger_snapshot,
          agent_program: program,
          contract_fingerprint: program.published_contract_fingerprint,
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

      def automation_entrypoint
        AgentRpc::KernelServices::ExecutionTargets::AutomationEntrypoint.new(
          id: automation_run.automation_id,
          permission_mode: automation_snapshot.fetch("permission_mode"),
          execution_target: bound_execution_target,
        )
      end

      def automation_snapshot
        @automation_snapshot ||= automation_run.snapshot.fetch("automation")
      end

      def bound_execution_target
        @bound_execution_target ||= ExecutionTarget.find(automation_snapshot.fetch("execution_target_id"))
      end

      def bound_conversation
        return @bound_conversation if defined?(@bound_conversation)

        conversation_id = automation_snapshot["conversation_id"].to_s.strip
        @bound_conversation =
          if conversation_id.present?
            Conversation.find(conversation_id)
          end
      end

      def selected_model_ref
        @selected_model_ref ||=
          begin
            value =
              automation_snapshot.dig("task_payload", "selected_model_ref").to_s.presence ||
                automation_run.automation.task_payload["selected_model_ref"].to_s.presence
            return value if value.present?

            AgentCore::ValidationError.raise!(
              "Automation dispatch is missing selected_model_ref.",
              code: "cybros.automations.selected_model_ref_missing",
              details: { automation_run_id: automation_run.id, automation_id: automation_run.automation_id },
            )
          end
      end

      def resolve_deployment!
        deployment = AgentProgram.find(automation_snapshot.fetch("agent_program_id")).active_healthy_deployment
        unless deployment&.activated_at.present?
          AgentCore::ValidationError.raise!(
            "Selected agent has no active healthy deployment.",
            code: "cybros.run_drafts.agent_deployment_missing",
            details: { agent_program_id: automation_snapshot.fetch("agent_program_id") },
          )
        end

        deployment
      end

      def trigger_snapshot
        @trigger_snapshot ||=
          begin
            snapshot = normalize_hash(automation_run.snapshot["trigger"])
            snapshot["automation_run_id"] = automation_run.id
            snapshot["conversation_id"] = bound_conversation.id if bound_conversation.present?
            snapshot["dag_node_id"] ||= bound_agent_node_id if bound_conversation.present?
            snapshot
          end
      end

      def bound_agent_node_id
        conversation = bound_conversation
        existing_id = automation_run.snapshot.dig("trigger", "dag_node_id").to_s.strip
        return existing_id if existing_id.present? && conversation.root_graph.nodes.exists?(id: existing_id)

        graph = conversation.root_graph
        lane = conversation.chat_lane
        node = nil

        graph.with_graph_lock! do
          sequence_parent = conversation.chat_head_leaf
          dependency_parent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
          mutations = DAG::Mutations.new(graph: graph, turn_id: automation_run.id)

          node =
            mutations.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              lane_id: lane.id,
              idempotency_key: "automation_run_agent",
              metadata: agent_node_metadata,
            )

          mutations.create_edge(from_node: sequence_parent, to_node: node, edge_type: DAG::Edge::SEQUENCE) if sequence_parent.present?

          if dependency_parent.present? && dependency_parent.id != node.id && !dependency_parent.terminal?
            mutations.create_edge(
              from_node: dependency_parent,
              to_node: node,
              edge_type: DAG::Edge::DEPENDENCY,
              metadata: { "generated_by" => "automation" },
            )
          end
        end

        node.id
      end

      def agent_node_metadata
        return {} if selected_model_ref.blank?

        { "llm" => { "model_ref" => selected_model_ref } }
      end

      def callback_methods
        bound_conversation.present? ? CONVERSATION_CALLBACK_METHODS : CALLBACK_METHODS_WITHOUT_CONVERSATION
      end

      def prepare_params(draft)
        {
          "invocation_id" => draft.prepare_invocation_id,
          "run_draft_id" => draft.id,
          "automation_id" => automation_run.automation_id,
          "automation_run_id" => automation_run.id,
          "conversation_id" => bound_conversation&.id,
          "user_input" => automation_snapshot.dig("task_payload", "prompt").to_s,
          "task_payload" => automation_snapshot["task_payload"],
          "trigger_snapshot" => draft.trigger_snapshot,
          "selected_model_ref" => draft.selected_model_ref,
          "permission_mode" => draft.permission_mode,
          "execution_target_id" => draft.proposed_execution_target_id,
          "public_settings" => bound_conversation&.public_settings || {},
          "agent_config" => bound_conversation&.selected_agent_config_for(draft.agent_program) || {},
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
  end
end
