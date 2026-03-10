require "digest"
require "json"
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
          :fit_tactics_applied,
        )

      NEAR_HARD_CAP_RATIO = 0.9

      def initialize(node:, runtime:, execution_context:)
        @node = node
        @graph = node.graph
        @runtime = runtime
        @execution_context = ExecutionContext.from(execution_context, instrumenter: runtime.instrumenter)
      end

      def build_prompt(context_nodes:)
        @execution_context = with_system_prompt_now_utc(@execution_context)
        prompt_assembly = PromptAssembly.new(runtime: @runtime, execution_context: @execution_context)

        context_nodes = without_target_node(normalize_initial_context(context_nodes))
        prepared = prompt_assembly.prepare(context_nodes: context_nodes)

        build =
          build_until_within_budget(
            prompt_assembly: prompt_assembly,
            prepared: prepared,
            context_nodes: context_nodes,
          )
        build = apply_prepare_turn(build, limit: effective_token_limit)

        metadata = budget_metadata(build, prepared: prepared)

        Result.new(built_prompt: build.built_prompt, context_nodes: build.context_nodes, metadata: metadata)
      end

      private

        def with_system_prompt_now_utc(context)
          ctx = ExecutionContext.from(context, instrumenter: @runtime.instrumenter)

          existing = ctx.attributes[:system_prompt_now_utc].to_s.strip
          return ctx unless existing.empty?

          now_utc = ctx.clock.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          ExecutionContext.from(ctx, system_prompt_now_utc: now_utc)
        rescue StandardError
          ExecutionContext.from(context, instrumenter: @runtime.instrumenter)
        end

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
              fit_tactics_applied: false,
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
              fit_tactics_applied: memory_dropped,
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
              fit_tactics_applied: memory_dropped || fit_decisions_applied?(decisions),
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
            fit_tactics_applied: false,
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
              fit_tactics_applied: true,
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
              fit_tactics_applied: true,
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

        def apply_prepare_turn(build, limit:)
          runner = @runtime.runtime_surface_runner
          surface = @runtime.runtime_surface
          return build if runner.nil? || surface.nil?

          outcome =
            runner.run(
              surface: surface,
              stage: :prepare_turn,
              input: prepare_turn_input(build: build, limit: limit),
              execution_context: @execution_context,
            )

          decision = outcome.decision
          unless decision.is_a?(AgentCore::RuntimeSurface::Decisions::TurnRewrite)
            AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
              execution_context: @execution_context,
              stage: :prepare_turn,
              surface: surface,
              outcome: {
                applied: false,
                reason: "pass",
                estimated_tokens: build.estimate,
              },
            )
            return build
          end

          rewritten_prompt = build_prompt_from_runtime_surface(decision.prompt)
          rewritten_estimate = rewritten_prompt.estimate_tokens(token_counter: @runtime.token_counter)

          if !limit.nil? && !within_budget?(rewritten_estimate, limit: limit)
            AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
              execution_context: @execution_context,
              stage: :prepare_turn,
              surface: surface,
              outcome: {
                applied: false,
                reason: "budget_exceeded",
                estimated_tokens: rewritten_estimate,
                fallback: outcome.fallback?,
              },
            )
            return rebuild_build(
              build,
              decisions: Array(build.decisions) + [{ "type" => "prepare_turn_rewrite", "applied" => false, "reason" => "budget_exceeded", "fallback" => outcome.fallback? }],
            )
          end

          AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
            execution_context: @execution_context,
            stage: :prepare_turn,
            surface: surface,
            outcome: {
              applied: true,
              fallback: outcome.fallback?,
              estimated_tokens: rewritten_estimate,
            },
          )

          rebuild_build(
            build,
            built_prompt: rewritten_prompt,
            estimate: rewritten_estimate,
            decisions: Array(build.decisions) + [{ "type" => "prepare_turn_rewrite", "applied" => true, "fallback" => outcome.fallback? }],
          )
        rescue StandardError
          build
        end

        def prepare_turn_input(build:, limit:)
          budget_facts = budget_facts_for(build: build, limit: limit)

          AgentCore::RuntimeSurface::Inputs::PrepareTurn.new(
            prompt: build.built_prompt.to_h,
            context: build.context_nodes,
            budget: {
              effective_prompt_budget_tokens: budget_facts.fetch(:effective_prompt_budget_tokens, nil),
              effective_context_soft_limit_tokens: budget_facts.fetch(:effective_context_soft_limit_tokens, nil),
              estimated_tokens: estimated_total(build.estimate),
              budget_state: budget_facts.fetch(:budget_state),
            }.compact,
            capabilities: {
              prompt_mode: @runtime.prompt_mode,
            },
            helpers: nil,
          )
        end

        def build_prompt_from_runtime_surface(value)
          return value if value.is_a?(PromptBuilder::BuiltPrompt)

          hash = value.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(value) : {}
          messages = Array(hash.fetch(:messages, [])).map { |message| message.is_a?(Message) ? message : Message.from_h(message) }

          PromptBuilder::BuiltPrompt.new(
            system_prompt: hash.fetch(:system_prompt, "").to_s,
            messages: messages,
            tools: Array(hash.fetch(:tools, [])),
            options: hash.fetch(:options, {}).is_a?(Hash) ? hash.fetch(:options, {}) : {},
          )
        end

        def rebuild_build(build, built_prompt: build.built_prompt, estimate: build.estimate, decisions: build.decisions)
          Build.new(
            built_prompt: built_prompt,
            context_nodes: build.context_nodes,
            estimate: estimate,
            memory_dropped: build.memory_dropped,
            decisions: decisions,
            limit_turns: build.limit_turns,
            auto_compacted: build.auto_compacted,
            fit_tactics_applied: build.fit_tactics_applied,
          )
        end

        def context_cost_report(build, prepared:, limit:)
          estimate = build.estimate.is_a?(Hash) ? build.estimate : {}
          budget_facts = budget_facts_for(build: build, limit: limit)
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
            "effective_context_window_tokens" => budget_facts.fetch(:effective_context_window_tokens),
            "model_context_window_tokens" => budget_facts.fetch(:model_context_window_tokens, nil),
            "provider_context_window_tokens" => budget_facts.fetch(:provider_context_window_tokens, nil),
            "reserved_output_tokens" => @runtime.reserved_output_tokens,
            "effective_prompt_budget_tokens" => budget_facts.fetch(:effective_prompt_budget_tokens, nil),
            "context_soft_limit_tokens" => budget_facts.fetch(:context_soft_limit_tokens, nil),
            "context_soft_limit_ratio" => budget_facts.fetch(:context_soft_limit_ratio, nil),
            "effective_context_soft_limit_tokens" => budget_facts.fetch(:effective_context_soft_limit_tokens, nil),
            "budget_state" => budget_facts.fetch(:budget_state),
            "memory_dropped" => build.memory_dropped,
            "limit_turns" => build.limit_turns,
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
            "prompt_sections" => prompt_sections_report(base_system_prompt, build, prepared: prepared, memory_results: memory_results),
            "decisions" => Array(build.decisions).map { |d| d.is_a?(Hash) ? d : { "type" => d.to_s } },
          }.compact
        rescue StandardError
          {
            "context_window_tokens" => @runtime.context_window_tokens,
            "effective_context_window_tokens" => @runtime.context_window_tokens,
            "model_context_window_tokens" => @runtime.model_context_window_tokens,
            "provider_context_window_tokens" => @runtime.provider_context_window_tokens,
            "reserved_output_tokens" => @runtime.reserved_output_tokens,
            "effective_prompt_budget_tokens" => limit,
            "context_soft_limit_tokens" => @runtime.context_soft_limit_tokens,
            "context_soft_limit_ratio" => @runtime.context_soft_limit_ratio,
            "effective_context_soft_limit_tokens" => effective_context_soft_limit_tokens(limit: limit),
            "budget_state" => budget_state_for(build: build, limit: limit, effective_context_soft_limit_tokens: effective_context_soft_limit_tokens(limit: limit)),
            "estimated_tokens" => {
              "total" => estimate.fetch(:total, nil),
              "messages" => estimate.fetch(:messages, nil),
              "tools" => estimate.fetch(:tools, nil),
            }.compact,
            "decisions" => Array(build.decisions),
          }.compact
        end

        def prompt_sections_report(base_system_prompt, build, prepared:, memory_results:)
          token_counter = @runtime.token_counter

          prompt_context =
            PromptBuilder::Context.new(
              system_prompt: base_system_prompt.to_s,
              tools_registry: @runtime.tools_registry,
              memory_results: memory_results,
              variables: prompt_variables,
              prompt_mode: @runtime.prompt_mode,
              prompt_injection_items: prepared.prompt_injection_items,
              tool_policy: @runtime.tool_policy,
              skills_store: @runtime.skills_store,
              include_skill_locations: @runtime.include_skill_locations,
              execution_context: @execution_context,
              system_prompt_section_overrides: @runtime.system_prompt_section_overrides,
            )

          sections = PromptBuilder::SystemPromptSectionsBuilder.build(context: prompt_context)

          prefix = text_summary(sections.prefix_text.to_s, token_counter: token_counter)
          tail = text_summary(sections.tail_text.to_s, token_counter: token_counter)

          system_sections =
            Array(sections.sections).map do |section|
              content = section.content.to_s
              md = section.metadata.is_a?(Hash) ? section.metadata : {}

              {
                "id" => section.id.to_s,
                "stability" => section.stability.to_s,
                "order" => section.order.to_i,
                "bytes" => content.bytesize,
                "estimated_tokens" => token_counter.count_text(content),
                "metadata" => AgentCore::Utils.deep_stringify_keys(md),
              }.compact
            end

          tools_schema = tools_schema_report(build)
          preamble_messages = preamble_messages_report(prepared, token_counter: token_counter)

          {
            "system_prompt" => {
              "prefix" => prefix,
              "tail" => tail,
              "sections" => system_sections,
            },
            "tools_schema" => tools_schema,
            "preamble_messages" => preamble_messages,
          }.compact
        rescue StandardError
          nil
        end

        def text_summary(text, token_counter:)
          {
            "bytes" => text.to_s.bytesize,
            "estimated_tokens" => token_counter.count_text(text.to_s),
            "sha256" => Digest::SHA256.hexdigest(text.to_s),
          }
        rescue StandardError
          { "bytes" => 0, "estimated_tokens" => 0, "sha256" => Digest::SHA256.hexdigest("") }
        end

        def tools_schema_report(build)
          tools = Array(build.built_prompt.tools)
          bytes =
            begin
              JSON.generate(tools).bytesize
            rescue StandardError
              0
            end

          estimate = build.estimate.is_a?(Hash) ? build.estimate : {}
          tool_tokens = estimate.fetch(:tools, nil)

          {
            "tool_count" => tools.length,
            "bytes" => bytes,
            "estimated_tokens" => tool_tokens,
          }.compact
        rescue StandardError
          nil
        end

        def preamble_messages_report(prepared, token_counter:)
          items =
            Array(prepared.prompt_injection_items)
              .select { |item| item.respond_to?(:preamble_message?) && item.preamble_message? }
              .each_with_index
              .sort_by { |(item, idx)| [item.order.to_i, idx] }
              .filter_map do |(item, idx)|
                if item.respond_to?(:allowed_in_prompt_mode?) && !item.allowed_in_prompt_mode?(@runtime.prompt_mode)
                  next
                end

                role = item.role.to_sym
                next unless role == :user || role == :assistant

                content = item.content.to_s
                next if content.strip.empty?

                id =
                  if item.respond_to?(:id) && item.id.to_s.strip != ""
                    item.id.to_s
                  else
                    "preamble_injection:#{idx + 1}"
                  end

                md = item.respond_to?(:metadata) && item.metadata.is_a?(Hash) ? item.metadata : {}

                {
                  "id" => id,
                  "role" => role.to_s,
                  "order" => item.order.to_i,
                  "bytes" => content.bytesize,
                  "estimated_tokens" => token_counter.count_text(content),
                  "metadata" => AgentCore::Utils.deep_stringify_keys(md),
                }.compact
              end

          items
        rescue StandardError
          []
        end

        def prompt_variables
          attrs = @execution_context.attributes
          vars = attrs[:variables] || attrs[:prompt_variables]
          vars.is_a?(Hash) ? vars : {}
        rescue StandardError
          {}
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

          soft_messages, soft_stats = pruner.call(messages: built_prompt.messages)
          soft_stats = soft_stats.is_a?(Hash) ? soft_stats : {}

          soft_trimmed_count =
            Integer(
              soft_stats.fetch(:trimmed_count, 0),
              exception: false
            ) || 0

          soft_chars_saved =
            Integer(
              soft_stats.fetch(:chars_saved, 0),
              exception: false
            ) || 0

          prompt_after_soft = built_prompt
          estimate_after_soft = estimate

          if soft_trimmed_count > 0
            prompt_after_soft =
              PromptBuilder::BuiltPrompt.new(
                system_prompt: built_prompt.system_prompt,
                messages: soft_messages,
                tools: built_prompt.tools,
                options: built_prompt.options,
              )

            estimate_after_soft = prompt_after_soft.estimate_tokens(token_counter: @runtime.token_counter)
          end

          prompt_after_hard = prompt_after_soft
          estimate_after_hard = estimate_after_soft
          hard_cleared_count = 0
          hard_chars_saved = 0

          if !within_budget?(estimate_after_soft, limit: limit) && pruner.hard_clear_enabled == true
            candidate_indexes = pruner.hard_clear_candidate_indexes(messages: prompt_after_soft.messages)

            if candidate_indexes.any?
              prunable_total_chars =
                Array(candidate_indexes).sum { |idx| pruner.prunable_body_chars(prompt_after_soft.messages[idx]) }

              if prunable_total_chars >= pruner.hard_clear_min_total_chars
                messages = prompt_after_soft.messages.dup

                Array(candidate_indexes).each do |idx|
                  break if within_budget?(estimate_after_hard, limit: limit)

                  msg = messages[idx]
                  next unless msg.is_a?(Message)

                  cleared = pruner.hard_clear_message(msg)
                  next unless cleared.is_a?(Message)

                  before = msg.text.to_s
                  after = cleared.text.to_s
                  next if after.length >= before.length

                  messages[idx] = cleared
                  hard_cleared_count += 1
                  hard_chars_saved += before.length - after.length

                  prompt_after_hard =
                    PromptBuilder::BuiltPrompt.new(
                      system_prompt: built_prompt.system_prompt,
                      messages: messages,
                      tools: built_prompt.tools,
                      options: built_prompt.options,
                    )

                  estimate_after_hard = prompt_after_hard.estimate_tokens(token_counter: @runtime.token_counter)
                end
              end
            end
          end

          return [built_prompt, estimate] if soft_trimmed_count <= 0 && hard_cleared_count <= 0

          attempt =
            Array(decisions).count { |d|
              d.is_a?(Hash) && d.fetch("type", nil).to_s == "prune_tool_outputs"
            } + 1

          decision = {
            "type" => "prune_tool_outputs",
            "attempt" => attempt,
            "recent_turns" => pruner.recent_turns,
            "keep_last_assistant_messages" => pruner.keep_last_assistant_messages,
            "tools_allow_count" => pruner.tools_allow_count,
            "tools_deny_count" => pruner.tools_deny_count,
            "soft_trim" => {
              "max_chars" => pruner.soft_trim_max_chars,
              "head_chars" => pruner.soft_trim_head_chars,
              "tail_chars" => pruner.soft_trim_tail_chars,
              "trimmed_count" => soft_trimmed_count,
              "chars_saved" => soft_chars_saved,
            }.compact,
            "hard_clear" => {
              "enabled" => pruner.hard_clear_enabled,
              "min_total_chars" => pruner.hard_clear_min_total_chars,
              "placeholder_chars" => pruner.hard_clear_placeholder.to_s.length,
              "cleared_count" => hard_cleared_count,
              "chars_saved" => hard_chars_saved,
              "triggered" => hard_cleared_count > 0,
            }.compact,
            "chars_saved_total" => soft_chars_saved + hard_chars_saved,
          }.compact

          decisions << decision

          [prompt_after_hard, estimate_after_hard]
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

        def budget_facts_for(build:, limit:)
          effective_context_soft_limit_tokens = effective_context_soft_limit_tokens(limit: limit)

          {
            effective_context_window_tokens: @runtime.context_window_tokens,
            model_context_window_tokens: @runtime.model_context_window_tokens,
            provider_context_window_tokens: @runtime.provider_context_window_tokens,
            effective_prompt_budget_tokens: limit,
            context_soft_limit_tokens: @runtime.context_soft_limit_tokens,
            context_soft_limit_ratio: @runtime.context_soft_limit_ratio,
            effective_context_soft_limit_tokens: effective_context_soft_limit_tokens,
            budget_state: budget_state_for(
              build: build,
              limit: limit,
              effective_context_soft_limit_tokens: effective_context_soft_limit_tokens,
            ),
          }
        end

        def effective_context_soft_limit_tokens(limit:)
          return nil if limit.nil?

          token_limit = @runtime.context_soft_limit_tokens
          ratio_limit =
            if @runtime.context_soft_limit_ratio.nil?
              nil
            else
              (limit * @runtime.context_soft_limit_ratio).floor
            end

          soft_limit = [token_limit, ratio_limit].compact.min
          return nil if soft_limit.nil?

          [soft_limit, limit].min
        end

        def budget_state_for(build:, limit:, effective_context_soft_limit_tokens:)
          return "normal" if limit.nil?
          return "forced_fit" if build.fit_tactics_applied

          estimate_total = estimated_total(build.estimate)
          near_hard_cap_threshold = (limit * NEAR_HARD_CAP_RATIO).floor

          return "near_hard_cap" if estimate_total >= near_hard_cap_threshold
          return "soft_limit_reached" if !effective_context_soft_limit_tokens.nil? && estimate_total >= effective_context_soft_limit_tokens

          "normal"
        end

        def estimated_total(estimate)
          return 0 unless estimate.is_a?(Hash)

          estimate.fetch(:total, 0)
        rescue StandardError
          0
        end

        def fit_decisions_applied?(decisions)
          Array(decisions).any? do |decision|
            next false unless decision.is_a?(Hash)

            %w[drop_memory_results prune_tool_outputs shrink_turns].include?(decision.fetch("type", nil).to_s)
          end
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
          summarizer.summarize(
            previous_summary: nil,
            transcript: transcript,
            max_output_tokens: @runtime.summary_max_tokens,
            runtime_governance: summary_runtime_governance,
          )
        end

        def summary_runtime_governance
          raw = @execution_context&.attributes&.fetch(:runtime_governance, nil)
          return nil unless raw.is_a?(Hash)

          governance = AgentCore::Utils.deep_symbolize_keys(raw)
          namespace = summary_request_namespace
          owner_id = @execution_context&.attributes&.dig(:dag, :node_id).to_s.strip
          owner_id = @execution_context&.run_id.to_s.strip if owner_id.empty?
          governance[:request_namespace] = namespace if governance[:request_namespace].to_s.strip.empty? && namespace.present?
          if governance[:provider_request_id].to_s.strip.empty? && namespace.present?
            governance[:provider_request_id] = "#{namespace}:attempt:1"
          end
          governance[:owner_type] = "DAG::Node" if governance[:owner_type].to_s.strip.empty?
          governance[:owner_id] = owner_id if governance[:owner_id].to_s.strip.empty? && owner_id.present?
          governance[:instrumenter] ||= @execution_context&.instrumenter
          governance[:estimated_tokens] = @runtime.summary_max_tokens unless governance.key?(:estimated_tokens)
          governance
        rescue StandardError
          nil
        end

        def summary_request_namespace
          [
            @execution_context&.run_id.to_s.strip.presence,
            @execution_context&.attributes&.dig(:dag, :node_id).to_s.strip.presence,
            "summary",
          ].compact.join(":")
        end
    end
  end
end
