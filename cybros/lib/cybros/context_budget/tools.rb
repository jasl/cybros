module Cybros
  module ContextBudget
    module Tools
      module_function

      def build
        [build_compact_context_tool]
      end

      def build_compact_context_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "compact_context",
          description: "Compact older conversation context into a shorter durable summary for the current lane.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "reason" => { type: "string", description: "Why the compaction is being requested." },
              "target" => { type: "string", description: "Compaction target, for example older_turns." },
            },
          },
          metadata: { source: :cybros, category: :context_budget, permission_class: "write" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node)
          graph = task_node.graph
          lane = graph.lanes.find(task_node.lane_id)
          runtime = AgentCore::DAG.runtime_for(node: task_node)

          plan =
            Conversation::ContextCompactionPlan.plan(
              conversation: conversation,
              content: "",
              runtime_surface_resolution: runtime_surface_resolution_for(runtime),
            )

          reason = args.fetch("reason", nil).to_s.presence || "manual"
          target = args.fetch("target", nil).to_s.presence || "older_turns"

          if plan.required?
            apply_compaction!(graph: graph, lane: lane, turn_ids: plan.compacted_turn_ids)

            AgentCore::Resources::Tools::ToolResult.success(
              text: plan.summary_text.to_s,
              metadata: {
                "reason" => reason,
                "target" => target,
                "noop" => false,
                "compacted_turn_ids" => plan.compacted_turn_ids,
                "estimated_tokens_before" => plan.estimated_tokens,
                "effective_prompt_budget_tokens" => plan.effective_prompt_budget_tokens,
              },
            )
          else
            AgentCore::Resources::Tools::ToolResult.success(
              text: "Context already fits within the current prompt budget.",
              metadata: {
                "reason" => reason,
                "target" => target,
                "noop" => true,
                "prompt_projection" => {
                  "text" => "ok",
                  "include_tool_name_header" => false,
                },
                "compacted_turn_ids" => [],
                "estimated_tokens_before" => plan.estimated_tokens,
                "effective_prompt_budget_tokens" => plan.effective_prompt_budget_tokens,
              },
            )
          end
        end
      end

      def current_task_node!(context)
        node_id = context&.attributes&.dig(:dag, :node_id).to_s
        node = DAG::Node.find_by(id: node_id)
        return node if node

        AgentCore::ValidationError.raise!(
          "compact_context requires a current DAG task node",
          code: "cybros.context_budget.compact_context.current_task_node_required",
        )
      end
      private_class_method :current_task_node!

      def conversation_for!(task_node)
        conversation = task_node.graph.attachable
        return conversation if conversation.is_a?(Conversation)

        AgentCore::ValidationError.raise!(
          "compact_context requires a Conversation-backed DAG graph",
          code: "cybros.context_budget.compact_context.conversation_required",
          details: { attachable_type: task_node.graph.attachable_type.to_s },
        )
      end
      private_class_method :conversation_for!

      def apply_compaction!(graph:, lane:, turn_ids:)
        ids = Array(turn_ids).map(&:to_s).select(&:present?).uniq
        return if ids.empty?

        nodes = graph.nodes.active.where(lane_id: lane.id, turn_id: ids).to_a
        return if nodes.empty?

        at = Time.current
        lane.send(:apply_compact_context_visibility!, keep_nodes: [], exclude_nodes: nodes, at: at, now: at)
      end
      private_class_method :apply_compaction!

      def runtime_surface_resolution_for(runtime)
        return nil if runtime.nil?
        return nil if runtime.runtime_surface.nil? || runtime.runtime_surface_runner.nil?

        {
          runtime_surface: runtime.runtime_surface,
          runtime_surface_runner: runtime.runtime_surface_runner,
        }
      rescue StandardError
        nil
      end
      private_class_method :runtime_surface_resolution_for
    end
  end
end
