module Automations
  class ConversationOrchestrator
    def self.start!(conversation:, debug: {}, error: {})
      new(conversation: conversation, debug: debug, error: error).start!
    end

    def initialize(conversation:, debug:, error:)
      @conversation = conversation
      @debug = debug
      @error = error
    end

    def start!
      agent_node = ensure_agent_node!
      result =
        RunDrafts::ConversationTurnOrchestrator.enqueue!(
          conversation: conversation,
          initiated_by_user: initiated_by_user,
          selected_model_ref: selected_model_ref,
          trigger_snapshot: trigger_snapshot(agent_node),
          debug: debug,
          error: error,
        )

      draft = result.fetch(:draft)
      conversation_run = result.fetch(:conversation_run)

      if draft.status.to_s == RunDrafts::ConversationTurnPlanningService::AWAITING_APPROVAL_STATUS
        Automations::ExecutionStateRecorder.awaiting_approval!(conversation: conversation, draft: draft)
      elsif conversation_run.present?
        Automations::ExecutionStateRecorder.running!(conversation: conversation, draft: draft, conversation_run: conversation_run)
        conversation.root_graph.kick!
      else
        Automations::ExecutionStateRecorder.completed!(conversation: conversation, draft: draft)
      end

      result
    rescue StandardError => error
      latest_draft = conversation.run_drafts.order(created_at: :desc, id: :desc).first
      Automations::ExecutionStateRecorder.failed!(conversation: conversation, draft: latest_draft, error: error)
      raise
    end

    private

      attr_reader :conversation, :debug, :error

      def ensure_agent_node!
        existing_id = conversation.metadata.dig("automation_execution", "dag_node_id").to_s.strip
        existing_node = existing_id.present? ? conversation.root_graph.nodes.find_by(id: existing_id) : nil
        return existing_node if existing_node.present?

        node = nil
        graph = conversation.root_graph
        lane = conversation.chat_lane

        graph.with_graph_lock! do
          sequence_parent = conversation.chat_head_leaf
          dependency_parent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
          mutations = DAG::Mutations.new(graph: graph, turn_id: conversation.id)

          node =
            mutations.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              lane_id: lane.id,
              idempotency_key: "automation_execution_agent",
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

        Automations::ExecutionStateRecorder.attach_agent_node!(conversation: conversation, dag_node_id: node.id)
        node
      end

      def trigger_snapshot(agent_node)
        trigger = conversation.metadata["trigger"].is_a?(Hash) ? conversation.metadata["trigger"].deep_dup : {}
        trigger.merge(
          "automation_id" => conversation.automation_id,
          "conversation_id" => conversation.id,
          "dag_node_id" => agent_node.id,
          "dispatch_key" => conversation.automation_dispatch_key,
          "user_input" => automation_prompt_snapshot,
        ).compact
      end

      def selected_model_ref
        conversation.metadata.dig("llm", "model_ref").to_s.presence ||
          conversation.metadata.dig("automation", "task_payload", "selected_model_ref").to_s.presence ||
          conversation.automation&.task_payload&.fetch("selected_model_ref", "").to_s.presence ||
          AgentCore::ValidationError.raise!(
            "Automation dispatch is missing selected_model_ref.",
            code: "cybros.automations.selected_model_ref_missing",
            details: { automation_id: conversation.automation_id, conversation_id: conversation.id },
          )
      end

      def automation_prompt_snapshot
        conversation.metadata.dig("trigger", "user_input").to_s.presence ||
          conversation.metadata.dig("automation", "task_payload", "prompt").to_s
      end

      def initiated_by_user
        initiated_by_user_id = conversation.metadata.dig("automation_execution", "initiated_by_user_id").to_s.strip
        return nil if initiated_by_user_id.blank?

        User.find_by(id: initiated_by_user_id)
      end

      def agent_node_metadata
        return { "source" => "automation", "automation_id" => conversation.automation_id } if selected_model_ref.blank?

        {
          "source" => "automation",
          "automation_id" => conversation.automation_id,
          "llm" => { "model_ref" => selected_model_ref },
        }
      end
  end
end
