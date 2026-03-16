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
            build_compaction_plan(
              conversation: conversation,
              lane: lane,
              runtime: runtime,
            )
          estimated_tokens_offset =
            context_budget_estimated_tokens_offset_for(
              task_node: task_node,
              plan: plan,
            )
          if !plan.required? && estimated_tokens_offset.positive?
            plan =
              build_compaction_plan(
                conversation: conversation,
                lane: lane,
                runtime: runtime,
                estimated_tokens_offset: estimated_tokens_offset,
              )
          end

          reason = args.fetch("reason", nil).to_s.presence || "manual"
          target = args.fetch("target", nil).to_s.presence || "older_turns"

          if plan.required?
            apply_compaction!(graph: graph, lane: lane, turn_ids: plan.compacted_turn_ids)
            summary_entry =
              write_summary_to_prompt_buffer!(
                lane: lane,
                summary_text: plan.summary_text.to_s,
                reason: reason,
                target: target,
                compacted_turn_ids: plan.compacted_turn_ids,
                estimated_tokens_before: plan.estimated_tokens,
                effective_prompt_budget_tokens: plan.effective_prompt_budget_tokens,
                token_counter: token_counter_for(runtime: runtime, conversation: conversation),
              )

            AgentCore::Resources::Tools::ToolResult.success(
              text: plan.summary_text.to_s,
              metadata: {
                "reason" => reason,
                "target" => target,
                "noop" => false,
                "compacted_turn_ids" => plan.compacted_turn_ids,
                "estimated_tokens_before" => plan.estimated_tokens,
                "effective_prompt_budget_tokens" => plan.effective_prompt_budget_tokens,
                "prompt_buffer" => {
                  "buffer_name" => "summaries",
                  "entry_ids" => [summary_entry.id],
                },
                "prompt_projection" => {
                  "text" => "Context compacted into lane prompt buffer.",
                  "include_tool_name_header" => false,
                },
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

      def build_compaction_plan(conversation:, lane:, runtime:, estimated_tokens_offset: 0)
        Conversation::ContextCompactionPlan.plan(
          conversation: conversation,
          content: "",
          lane: lane,
          runtime_surface_resolution: runtime_surface_resolution_for(runtime),
          runtime: runtime,
          estimated_tokens_offset: estimated_tokens_offset,
        )
      end
      private_class_method :build_compaction_plan

      def context_budget_estimated_tokens_offset_for(task_node:, plan:)
        metadata = task_node.metadata.is_a?(Hash) ? task_node.metadata : {}
        context_budget = metadata.fetch("context_budget", nil)
        return 0 unless context_budget.is_a?(Hash)

        budget_estimate = context_budget.fetch("estimated_tokens", context_budget.fetch(:estimated_tokens, nil)).to_i
        return 0 unless budget_estimate.positive?

        [budget_estimate - plan.estimated_tokens.to_i, 0].max
      rescue StandardError
        0
      end
      private_class_method :context_budget_estimated_tokens_offset_for

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

      def write_summary_to_prompt_buffer!(lane:, summary_text:, reason:, target:, compacted_turn_ids:, estimated_tokens_before:, effective_prompt_budget_tokens:, token_counter:)
        content = summary_text.to_s.strip
        metadata = {
          "source" => "compact_context",
          "reason" => reason,
          "target" => target,
          "compacted_turn_ids" => compacted_turn_ids,
          "estimated_tokens_before" => estimated_tokens_before,
          "effective_prompt_budget_tokens" => effective_prompt_budget_tokens,
        }
        next_seq = lane.lane_prompt_buffer_entries.where(buffer_name: "summaries").maximum(:seq).to_i + AgentRPC::KernelServices::LanePromptBuffer::SEQ_STEP
        next_seq = AgentRPC::KernelServices::LanePromptBuffer::SEQ_STEP if next_seq <= 0

        lane.transaction do
          lane.lane_prompt_buffer_entries.create!(
            buffer_name: "summaries",
            seq: next_seq,
            kind: "summary",
            content: content,
            priority: 100,
            estimated_tokens: token_counter.count_text(content),
            metadata: metadata,
          )
        end
      end
      private_class_method :write_summary_to_prompt_buffer!

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

      def token_counter_for(runtime:, conversation:)
        return runtime.token_counter if runtime.respond_to?(:token_counter) && runtime.token_counter

        model_ref = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation).fetch(:model_ref)
        Cybros::AgentRuntimeResolver.token_counter_for_model_ref(model_ref: model_ref)
      end
      private_class_method :token_counter_for
    end
  end
end
