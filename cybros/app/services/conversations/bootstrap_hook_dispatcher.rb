module Conversations
  class BootstrapHookDispatcher
    def self.dispatch_created!(conversation:)
      new(conversation: conversation).dispatch_created!
    end

    def self.dispatch_lane_first_user_message!(conversation:, user_node:, anchor_node: nil)
      new(conversation: conversation).dispatch_lane_first_user_message!(user_node: user_node, anchor_node: anchor_node)
    end

    def initialize(conversation:)
      @conversation = conversation
    end

    def dispatch_created!
      return nil if !conversation.root? && conversation.dag_lane.blank?

      lane = conversation.chat_lane
      lane_head = conversation.chat_head_leaf

      dispatch_hook!(
        hook_name: "on_conversation_created",
        invocation_id: "conversation:#{conversation.id}:on_conversation_created",
        request_payload: base_payload(lane: lane, anchor_node: lane_head).merge(
          "conversation_id" => conversation.id,
          "conversation_kind" => conversation.kind,
          "agent_key" => conversation.metadata.dig("agent", "key").to_s.presence,
        ),
        lane: lane,
        anchor_node: lane_head,
      )
    end

    def dispatch_lane_first_user_message!(user_node:, anchor_node: nil)
      return if user_node.nil?

      lane = user_node.lane
      initialize_workspace_for!(lane: lane)
      resolved_anchor = anchor_node || default_first_user_anchor_for(user_node: user_node)

      dispatch_hook!(
        hook_name: "on_lane_first_user_message",
        invocation_id: "conversation:#{conversation.id}:lane:#{lane.id}:user:#{user_node.id}:on_lane_first_user_message",
        request_payload: base_payload(lane: lane, anchor_node: resolved_anchor).merge(
          "conversation_id" => conversation.id,
          "conversation_kind" => conversation.kind,
          "agent_key" => conversation.metadata.dig("agent", "key").to_s.presence,
          "user_node_id" => user_node.id,
          "content" => user_node.body_input["content"].to_s,
        ),
        lane: lane,
        anchor_node: resolved_anchor,
      )
    end

    private

      attr_reader :conversation

      def dispatch_hook!(hook_name:, invocation_id:, request_payload:, lane:, anchor_node:)
        deployment = deployment_for(hook_name)
        return nil if deployment.nil?

        envelope =
          Cybros::ProgrammableAgent::HookCaller.call!(
            deployment: deployment,
            conversation: conversation,
            scope_type: "conversation",
            scope_id: conversation.id,
            hook_name: hook_name,
            invocation_id: invocation_id,
            request_payload: request_payload,
            allowed_callback_methods: [],
          )

        result =
          Cybros::ProgrammableAgent::HookActionExecutor.execute!(
            hook_name: hook_name,
            actions: envelope.actions,
            placeholder_node: nil,
            anchor_node: anchor_node,
            lane: lane,
          )

        if envelope.actions.any? { |action| action.type == "create_task" }
          run_immediately_claimable_tasks!(graph: lane.graph)
          lane.graph.kick! if result.created_tasks.any? { |task| task.reload.pending? }
        end
        result
      end

      def deployment_for(hook_name)
        deployment = conversation.agent&.active_runtime_binding
        return nil if deployment.nil?
        return nil unless Array(deployment.supported_methods).include?(hook_name)
        return nil unless bootstrap_ready_deployment?(deployment)

        deployment
      end

      def bootstrap_ready_deployment?(deployment)
        snapshot = deployment.capability_snapshot
        snapshot = {} unless snapshot.is_a?(Hash)

        snapshot["capability_registry_snapshot_id"].to_s.presence || snapshot["snapshot_id"].to_s.presence
      end

      def base_payload(lane:, anchor_node:)
        {
          "graph_id" => lane.graph_id,
          "lane_id" => lane.id,
          "lane_role" => lane.role,
          "capability_registry_snapshot_id" => capability_registry_snapshot_id,
          "session_context" => Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h,
          "execution_context" => execution_context_for(lane: lane, anchor_node: anchor_node).to_h,
        }.compact
      end

      def execution_context_for(lane:, anchor_node:)
        if anchor_node.present?
          Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
            conversation: conversation,
            node: anchor_node,
          )
        else
          Cybros::ProgrammableAgent::ExecutionContext.from_conversation_step(
            conversation: conversation,
            dag_node_id: nil,
            node: nil,
          )
        end
      end

      def capability_registry_snapshot_id
        snapshot = conversation.agent&.active_runtime_binding&.capability_snapshot
        snapshot = {} unless snapshot.is_a?(Hash)
        snapshot["capability_registry_snapshot_id"].to_s.presence || snapshot["snapshot_id"].to_s.presence
      end

      def initialize_workspace_for!(lane:)
        return if lane.nil?
        return unless main_lane?(lane)

        Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      end

      def main_lane?(lane)
        conversation.chat_lane.id.to_s == lane.id.to_s
      rescue StandardError
        false
      end

      def default_first_user_anchor_for(user_node:)
        pending_agent =
          conversation.root_graph.nodes.active
            .where(
              lane_id: user_node.lane_id,
              turn_id: user_node.turn_id,
              node_type: Messages::AgentMessage.node_type_key,
              state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL],
            )
            .order(:id)
            .last
        return pending_agent if pending_agent.present?

        conversation.chat_head_leaf || user_node
      end

      def run_immediately_claimable_tasks!(graph:)
        10.times do
          claimed = []

          graph.with_graph_try_lock do
            DAG::RunningLeaseReclaimer.reclaim!(graph: graph)
            DAG::FailurePropagation.propagate!(graph: graph)
            graph.apply_visibility_patches_if_idle!
            claimed = DAG::Scheduler.claim_executable_nodes(
              graph: graph,
              limit: 10,
              claimed_by: "bootstrap_hook_dispatcher:#{conversation.id}",
            )
          end

          break if claimed.empty?

          claimed.each do |node|
            DAG::Runner.run_node!(
              node.id,
              execute_job_id: "bootstrap_hook_dispatcher",
              enqueue_follow_up: false,
            )
          end
        end
      end
  end
end
