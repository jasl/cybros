# frozen_string_literal: true

require "set"

module AgentCore
  module DAG
    class ContextBudgetManager
      Result =
        Data.define(
          :built_prompt,
          :context_nodes,
          :metadata,
        )

      def initialize(node:, runtime:, execution_context:, stream: nil)
        @node = node
        @graph = node.graph
        @runtime = runtime
        @execution_context = ExecutionContext.from(execution_context, instrumenter: runtime.instrumenter)
        @stream = stream
      end

      def build_prompt(context_nodes:)
        prompt_assembly = PromptAssembly.new(runtime: @runtime, execution_context: @execution_context)

        context_nodes = without_target_node(normalize_initial_context(context_nodes))
        prepared = prompt_assembly.prepare(context_nodes: context_nodes)

        built_prompt, estimate, memory_dropped =
          build_until_within_budget(
            prompt_assembly: prompt_assembly,
            prepared: prepared,
            context_nodes: context_nodes,
          )

        metadata = budget_metadata(estimate, memory_dropped: memory_dropped, limit_turns: current_limit_turns(context_nodes))

        Result.new(built_prompt: built_prompt, context_nodes: context_nodes, metadata: metadata)
      end

      private

        def normalize_initial_context(context_nodes)
          context_nodes = Array(context_nodes)
          return context_nodes if @runtime.context_turns == ::DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS

          @graph.context_for_full(@node.id, limit_turns: @runtime.context_turns)
        rescue StandardError
          context_nodes
        end

        def build_until_within_budget(prompt_assembly:, prepared:, context_nodes:)
          limit = effective_token_limit
          return build_without_budget(prompt_assembly: prompt_assembly, prepared: prepared, context_nodes: context_nodes) if limit.nil?

          estimate = nil

          built_prompt = prompt_assembly.build(
            context_nodes: context_nodes,
            memory_results: prepared.memory_results,
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)
          return [built_prompt, estimate, false] if within_budget?(estimate, limit: limit)

          built_prompt = prompt_assembly.build(
            context_nodes: context_nodes,
            memory_results: [],
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)
          memory_dropped = true

          return [built_prompt, estimate, memory_dropped] if within_budget?(estimate, limit: limit)

          shrink_turns_until_fit(
            prompt_assembly: prompt_assembly,
            prepared: prepared,
            initial_context_nodes: context_nodes,
            limit: limit,
            memory_dropped: memory_dropped,
          )
        end

        def build_without_budget(prompt_assembly:, prepared:, context_nodes:)
          built_prompt = prompt_assembly.build(
            context_nodes: context_nodes,
            memory_results: prepared.memory_results,
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)
          [built_prompt, estimate, false]
        end

        def shrink_turns_until_fit(prompt_assembly:, prepared:, initial_context_nodes:, limit:, memory_dropped:)
          auto_compact = @runtime.auto_compact
          auto_compacted = false

          limit_turns = current_limit_turns(initial_context_nodes)

          while limit_turns > 1
            limit_turns -= 1
            context_nodes = without_target_node(@graph.context_for_full(@node.id, limit_turns: limit_turns))

            built_prompt = prompt_assembly.build(
              context_nodes: context_nodes,
              memory_results: [],
              prompt_injection_items: prepared.prompt_injection_items,
            )

            estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

            next unless within_budget?(estimate, limit: limit)

            if auto_compact && !auto_compacted
              auto_compacted = try_auto_compact!(from_context_nodes: initial_context_nodes, to_context_nodes: context_nodes)
              if auto_compacted
                context_nodes = without_target_node(@graph.context_for_full(@node.id, limit_turns: limit_turns))
                built_prompt = prompt_assembly.build(
                  context_nodes: context_nodes,
                  memory_results: [],
                  prompt_injection_items: prepared.prompt_injection_items,
                )
                estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

                next unless within_budget?(estimate, limit: limit)
              end
            end

            return [built_prompt, estimate, memory_dropped]
          end

          built_prompt = prompt_assembly.build(
            context_nodes: without_target_node(@graph.context_for_full(@node.id, limit_turns: 1)),
            memory_results: [],
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          raise ContextWindowExceededError.new(
            "prompt exceeds context window even after trimming",
            estimated_tokens: estimate.fetch(:total),
            message_tokens: estimate.fetch(:messages),
            tool_tokens: estimate.fetch(:tools),
            context_window: @runtime.context_window_tokens,
            reserved_output: @runtime.reserved_output_tokens,
          )
        end

        def without_target_node(context_nodes)
          target_id = @node.id.to_s
          Array(context_nodes).reject { |n| n.fetch("node_id").to_s == target_id }
        rescue StandardError
          Array(context_nodes)
        end

        def within_budget?(estimate, limit:)
          estimate.fetch(:total) <= limit
        rescue StandardError
          false
        end

        def effective_token_limit
          window = @runtime.context_window_tokens
          return nil if window.nil?

          limit = window - @runtime.reserved_output_tokens
          limit.negative? ? 0 : limit
        end

        def budget_metadata(estimate, memory_dropped:, limit_turns:)
          limit = effective_token_limit

          {
            context_budget: {
              context_window_tokens: @runtime.context_window_tokens,
              reserved_output_tokens: @runtime.reserved_output_tokens,
              limit: limit,
              estimated_prompt_tokens: estimate.fetch(:total),
              estimated_prompt_tokens_breakdown: estimate,
              memory_dropped: memory_dropped,
              limit_turns: limit_turns,
              auto_compact: @runtime.auto_compact,
            }.compact,
          }
        rescue StandardError
          {}
        end

        def current_limit_turns(context_nodes)
          turn_ids =
            Array(context_nodes)
              .map { |n| n.fetch("turn_id", nil).to_s }
              .reject(&:empty?)
              .uniq
              .sort

          turn_ids.length
        rescue StandardError
          @runtime.context_turns
        end

        def try_auto_compact!(from_context_nodes:, to_context_nodes:)
          dropped = dropped_node_ids(from_context_nodes: from_context_nodes, to_context_nodes: to_context_nodes)
          return false if dropped.empty?

          transcript = transcript_for_node_ids(from_context_nodes, dropped)
          return false if transcript.strip.empty?

          summary = summarize_transcript(transcript)
          return false if summary.strip.empty?

          @graph.compress!(
            node_ids: dropped,
            summary_content: summary,
            summary_metadata: { "generated_by" => "agent_core", "kind" => "auto_compact" }
          )

          true
        rescue StandardError
          false
        end

        def dropped_node_ids(from_context_nodes:, to_context_nodes:)
          to_ids = Array(to_context_nodes).map { |n| n.fetch("node_id").to_s }.to_set
          lane_id = @node.lane_id.to_s

          dropped =
            Array(from_context_nodes).filter_map do |n|
              id = n.fetch("node_id").to_s
              next if to_ids.include?(id)
              next unless n.fetch("lane_id", "").to_s == lane_id

              node_type = n.fetch("node_type").to_s
              next if %w[system_message developer_message summary].include?(node_type)

              state = n.fetch("state").to_s
              next unless state == ::DAG::Node::FINISHED

              id
            end

          dropped.uniq
        rescue StandardError
          []
        end

        def transcript_for_node_ids(context_nodes, node_ids)
          ids = node_ids.to_set

          lines = []

          Array(context_nodes).each do |n|
            next unless ids.include?(n.fetch("node_id").to_s)

            payload = n.fetch("payload") { {} }
            input = payload.fetch("input") { {} }
            output = payload.fetch("output") { {} }
            metadata = n.fetch("metadata") { {} }

            node_type = n.fetch("node_type").to_s
            state = n.fetch("state").to_s

            case node_type
            when "user_message"
              content = input.is_a?(Hash) ? input.fetch("content", "").to_s : ""
              lines << "User: #{content}".strip
            when "agent_message", "character_message"
              content = output.is_a?(Hash) ? output.fetch("content", "").to_s : ""
              lines << "Assistant: #{content}".strip
            when "task"
              name = input.is_a?(Hash) ? input.fetch("name", "").to_s : ""
              if state == ::DAG::Node::FINISHED && output.is_a?(Hash) && output.key?("result")
                result_text =
                  begin
                    result = AgentCore::Resources::Tools::ToolResult.from_h(output.fetch("result"))
                    result.text
                  rescue StandardError
                    output.fetch("result").to_s
                  end

                lines << "Tool(#{name}): #{result_text}".strip
              elsif state == ::DAG::Node::ERRORED
                error = metadata.is_a?(Hash) ? metadata.fetch("error", "").to_s : ""
                lines << "Tool(#{name}) errored: #{error}".strip
              else
                lines << "Tool(#{name}) state=#{state}".strip
              end
            end
          end

          lines.reject(&:empty?).join("\n")
        rescue StandardError
          ""
        end

        def summarize_transcript(transcript)
          model = @runtime.summary_model || @runtime.model
          summarizer = AgentCore::ContextManagement::Summarizer.new(provider: @runtime.provider, model: model)
          summarizer.summarize(previous_summary: nil, transcript: transcript, max_output_tokens: @runtime.summary_max_tokens)
        end
    end
  end
end
