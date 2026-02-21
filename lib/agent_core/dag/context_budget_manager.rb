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

      Build =
        Data.define(
          :built_prompt,
          :context_nodes,
          :estimate,
          :memory_dropped,
          :decisions,
          :limit_turns,
          :auto_compacted,
        )

      def initialize(node:, runtime:, execution_context:)
        @node = node
        @graph = node.graph
        @runtime = runtime
        @execution_context = ExecutionContext.from(execution_context, instrumenter: runtime.instrumenter)
      end

      def build_prompt(context_nodes:)
        prompt_assembly = PromptAssembly.new(runtime: @runtime, execution_context: @execution_context)

        context_nodes = without_target_node(normalize_initial_context(context_nodes))
        prepared = prompt_assembly.prepare(context_nodes: context_nodes)

        build =
          build_until_within_budget(
            prompt_assembly: prompt_assembly,
            prepared: prepared,
            context_nodes: context_nodes,
          )

        metadata = budget_metadata(build, prepared: prepared)

        Result.new(built_prompt: build.built_prompt, context_nodes: build.context_nodes, metadata: metadata)
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
          decisions = []

          return build_without_budget(prompt_assembly: prompt_assembly, prepared: prepared, context_nodes: context_nodes) if limit.nil?

          built_prompt =
            prompt_assembly.build(
              context_nodes: context_nodes,
              memory_results: prepared.memory_results,
              prompt_injection_items: prepared.prompt_injection_items,
            )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          if within_budget?(estimate, limit: limit)
            return Build.new(
              built_prompt: built_prompt,
              context_nodes: context_nodes,
              estimate: estimate,
              memory_dropped: false,
              decisions: decisions,
              limit_turns: current_limit_turns(context_nodes),
              auto_compacted: false,
            )
          end

          memory_dropped = Array(prepared.memory_results).any?
          decisions << { "type" => "drop_memory_results" } if memory_dropped

          built_prompt =
            prompt_assembly.build(
              context_nodes: context_nodes,
              memory_results: [],
              prompt_injection_items: prepared.prompt_injection_items,
            )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          if within_budget?(estimate, limit: limit)
            return Build.new(
              built_prompt: built_prompt,
              context_nodes: context_nodes,
              estimate: estimate,
              memory_dropped: memory_dropped,
              decisions: decisions,
              limit_turns: current_limit_turns(context_nodes),
              auto_compacted: false,
            )
          end

          built_prompt, estimate =
            maybe_prune_tool_outputs(
              built_prompt,
              estimate,
              limit: limit,
              decisions: decisions,
            )

          if within_budget?(estimate, limit: limit)
            return Build.new(
              built_prompt: built_prompt,
              context_nodes: context_nodes,
              estimate: estimate,
              memory_dropped: memory_dropped,
              decisions: decisions,
              limit_turns: current_limit_turns(context_nodes),
              auto_compacted: false,
            )
          end

          shrink_turns_until_fit(
            prompt_assembly: prompt_assembly,
            prepared: prepared,
            initial_context_nodes: context_nodes,
            limit: limit,
            memory_dropped: memory_dropped,
            decisions: decisions,
          )
        end

        def build_without_budget(prompt_assembly:, prepared:, context_nodes:)
          built_prompt = prompt_assembly.build(
            context_nodes: context_nodes,
            memory_results: prepared.memory_results,
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          Build.new(
            built_prompt: built_prompt,
            context_nodes: context_nodes,
            estimate: estimate,
            memory_dropped: false,
            decisions: [],
            limit_turns: current_limit_turns(context_nodes),
            auto_compacted: false,
          )
        end

        def shrink_turns_until_fit(prompt_assembly:, prepared:, initial_context_nodes:, limit:, memory_dropped:, decisions:)
          auto_compact = @runtime.auto_compact
          auto_compacted = false

          limit_turns = current_limit_turns(initial_context_nodes)
          initial_limit_turns = limit_turns

          while limit_turns > 1
            limit_turns -= 1
            context_nodes = without_target_node(@graph.context_for_full(@node.id, limit_turns: limit_turns))

            built_prompt = prompt_assembly.build(
              context_nodes: context_nodes,
              memory_results: [],
              prompt_injection_items: prepared.prompt_injection_items,
            )

            estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

            unless within_budget?(estimate, limit: limit)
              built_prompt, estimate =
                maybe_prune_tool_outputs(
                  built_prompt,
                  estimate,
                  limit: limit,
                  decisions: decisions,
                )

              next unless within_budget?(estimate, limit: limit)
            end

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

                unless within_budget?(estimate, limit: limit)
                  built_prompt, estimate =
                    maybe_prune_tool_outputs(
                      built_prompt,
                      estimate,
                      limit: limit,
                      decisions: decisions,
                    )

                  next unless within_budget?(estimate, limit: limit)
                end
              end
            end

            decisions << { "type" => "shrink_turns", "limit_turns" => limit_turns } if limit_turns != initial_limit_turns
            decisions << { "type" => "auto_compact", "triggered" => auto_compacted } if auto_compact

            return Build.new(
              built_prompt: built_prompt,
              context_nodes: context_nodes,
              estimate: estimate,
              memory_dropped: memory_dropped,
              decisions: decisions,
              limit_turns: limit_turns,
              auto_compacted: auto_compacted,
            )
          end

          context_nodes = without_target_node(@graph.context_for_full(@node.id, limit_turns: 1))
          built_prompt = prompt_assembly.build(
            context_nodes: context_nodes,
            memory_results: [],
            prompt_injection_items: prepared.prompt_injection_items,
          )
          estimate = built_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          unless within_budget?(estimate, limit: limit)
            built_prompt, estimate =
              maybe_prune_tool_outputs(
                built_prompt,
                estimate,
                limit: limit,
                decisions: decisions,
              )
          end

          if within_budget?(estimate, limit: limit)
            decisions << { "type" => "shrink_turns", "limit_turns" => 1 } if 1 != initial_limit_turns
            decisions << { "type" => "auto_compact", "triggered" => auto_compacted } if auto_compact

            return Build.new(
              built_prompt: built_prompt,
              context_nodes: context_nodes,
              estimate: estimate,
              memory_dropped: memory_dropped,
              decisions: decisions,
              limit_turns: 1,
              auto_compacted: auto_compacted,
            )
          end

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

        def budget_metadata(build, prepared:)
          limit = effective_token_limit

          {
            "context_cost" => context_cost_report(build, prepared: prepared, limit: limit),
          }
        rescue StandardError
          {}
        end

        def context_cost_report(build, prepared:, limit:)
          estimate = build.estimate.is_a?(Hash) ? build.estimate : {}
          token_counter = @runtime.token_counter

          memory_results = build.memory_dropped ? [] : Array(prepared.memory_results)
          memory_knowledge_tokens =
            if memory_results.any?
              memory_text = memory_results.map { |e| e.respond_to?(:content) ? e.content.to_s : e.to_s }.join("\n\n")
              token_counter.count_text("<relevant_context>\n#{memory_text}\n</relevant_context>")
            else
              0
            end

          base_system_prompt =
            begin
              ContextAdapter.new(context_nodes: build.context_nodes).call.system_prompt.to_s
            rescue StandardError
              ""
            end

          system_prompt_tokens =
            begin
              token_counter.count_text(build.built_prompt.system_prompt.to_s)
            rescue StandardError
              0
            end

          base_system_prompt_tokens =
            begin
              token_counter.count_text(base_system_prompt)
            rescue StandardError
              0
            end

          system_injections_tokens = system_prompt_tokens - base_system_prompt_tokens - memory_knowledge_tokens
          system_injections_tokens = 0 if system_injections_tokens.negative?

          preamble_count = preamble_injection_message_count(prepared.prompt_injection_items)
          prompt_messages = Array(build.built_prompt.messages)
          preamble_messages = preamble_count.positive? ? prompt_messages.first(preamble_count) : []

          tool_result_messages = prompt_messages.select { |m| tool_result_message?(m) }
          history_messages = prompt_messages.drop(preamble_messages.length).reject { |m| tool_result_message?(m) }

          injections_tokens =
            begin
              token_counter.count_messages(preamble_messages) + system_injections_tokens
            rescue StandardError
              system_injections_tokens
            end

          {
            "context_window_tokens" => @runtime.context_window_tokens,
            "reserved_output_tokens" => @runtime.reserved_output_tokens,
            "limit" => limit,
            "memory_dropped" => build.memory_dropped,
            "limit_turns" => build.limit_turns,
            "auto_compact" => @runtime.auto_compact,
            "estimated_tokens" => {
              "total" => estimate.fetch(:total, nil),
              "messages" => estimate.fetch(:messages, nil),
              "tools" => estimate.fetch(:tools, nil),
            }.compact,
            "estimated_tokens_coarse" => {
              "tools_schema" => estimate.fetch(:tools, nil),
              "tool_results" => token_counter.count_messages(tool_result_messages),
              "history" => token_counter.count_messages(history_messages),
              "injections" => injections_tokens,
              "memory_knowledge" => memory_knowledge_tokens,
            }.compact,
            "decisions" => Array(build.decisions).map { |d| d.is_a?(Hash) ? d : { "type" => d.to_s } },
          }.compact
        rescue StandardError
          {
            "context_window_tokens" => @runtime.context_window_tokens,
            "reserved_output_tokens" => @runtime.reserved_output_tokens,
            "limit" => limit,
            "estimated_tokens" => {
              "total" => estimate.fetch(:total, nil),
              "messages" => estimate.fetch(:messages, nil),
              "tools" => estimate.fetch(:tools, nil),
            }.compact,
            "decisions" => Array(build.decisions),
          }.compact
        end

        def preamble_injection_message_count(prompt_injection_items)
          count = 0

          Array(prompt_injection_items)
            .select { |item| item.respond_to?(:preamble_message?) && item.preamble_message? }
            .each_with_index
            .sort_by { |(item, idx)| [item.order.to_i, idx] }
            .each do |(item, _)|
              if item.respond_to?(:allowed_in_prompt_mode?) && !item.allowed_in_prompt_mode?(@runtime.prompt_mode)
                next
              end

              role = item.role.to_sym
              next unless role == :user || role == :assistant

              content = item.content.to_s
              next if content.strip.empty?

              count += 1
            end

          count
        rescue StandardError
          0
        end

        def tool_result_message?(msg)
          return true if msg.respond_to?(:tool_result?) && msg.tool_result?

          return false unless msg.respond_to?(:system?) && msg.system?

          text = msg.respond_to?(:text) ? msg.text.to_s : ""
          text.start_with?("[tool:")
        rescue StandardError
          false
        end

        def maybe_prune_tool_outputs(built_prompt, estimate, limit:, decisions:)
          return [built_prompt, estimate] if within_budget?(estimate, limit: limit)

          pruner = @runtime.tool_output_pruner
          return [built_prompt, estimate] if pruner.nil?

          pruned_messages, stats = pruner.call(messages: built_prompt.messages)
          stats = stats.is_a?(Hash) ? stats : {}

          trimmed_count =
            Integer(
              stats.fetch(:trimmed_count, stats.fetch("trimmed_count", 0)),
              exception: false
            ) || 0
          return [built_prompt, estimate] if trimmed_count <= 0

          chars_saved =
            Integer(
              stats.fetch(:chars_saved, stats.fetch("chars_saved", 0)),
              exception: false
            ) || 0

          attempt =
            Array(decisions).count { |d|
              d.is_a?(Hash) && d.fetch("type", nil).to_s == "prune_tool_outputs"
            } + 1

          decisions << {
            "type" => "prune_tool_outputs",
            "attempt" => attempt,
            "recent_turns" => (pruner.respond_to?(:recent_turns) ? pruner.recent_turns : nil),
            "max_output_chars" => (pruner.respond_to?(:max_output_chars) ? pruner.max_output_chars : nil),
            "preview_chars" => (pruner.respond_to?(:preview_chars) ? pruner.preview_chars : nil),
            "trimmed_count" => trimmed_count,
            "chars_saved" => chars_saved,
          }.compact

          pruned_prompt =
            PromptBuilder::BuiltPrompt.new(
              system_prompt: built_prompt.system_prompt,
              messages: pruned_messages,
              tools: built_prompt.tools,
              options: built_prompt.options,
            )

          pruned_estimate = pruned_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          [pruned_prompt, pruned_estimate]
        rescue StandardError
          [built_prompt, estimate]
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
