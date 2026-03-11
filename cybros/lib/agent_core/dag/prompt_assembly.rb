require "json"

module AgentCore
  module DAG
    class PromptAssembly
      VisibleToolsRegistry =
        Data.define(:definitions_list) do
          def definitions(format: :generic)
            _ = format
            definitions_list
          end
        end

      Prepared =
        Data.define(
          :latest_user_message,
          :memory_results,
          :prompt_injection_items,
        )

      def initialize(runtime:, execution_context:)
        @runtime = runtime
        @execution_context = ExecutionContext.from(execution_context, instrumenter: runtime.instrumenter)
      end

      def prepare(context_nodes:)
        adapted = ContextAdapter.new(context_nodes: context_nodes).call
        latest_user_message = adapted.latest_user_message

        Prepared.new(
          latest_user_message: latest_user_message,
          memory_results: lookup_memory(latest_user_message),
          prompt_injection_items: build_prompt_injection_items(latest_user_message),
        )
      end

      def final_prompt_injection_items(prompt_injection_items: :auto, latest_user_message: nil)
        base_items =
          if prompt_injection_items == :auto
            build_prompt_injection_items(latest_user_message)
          else
            Array(prompt_injection_items)
          end

        Array(base_items).dup + context_budget_prompt_injection_items(visible_tools: visible_tool_definitions)
      rescue StandardError
        prompt_injection_items == :auto ? build_prompt_injection_items(latest_user_message) : Array(prompt_injection_items)
      end

      def build(context_nodes:, memory_results: :auto, prompt_injection_items: :auto)
        adapted = ContextAdapter.new(context_nodes: context_nodes).call
        latest_user_message = adapted.latest_user_message

        memory_results = lookup_memory(latest_user_message) if memory_results == :auto
        memory_results = Array(memory_results)

        visible_tools = visible_tool_definitions
        prompt_injection_items =
          if prompt_injection_items == :auto
            final_prompt_injection_items(
              latest_user_message: latest_user_message,
              prompt_injection_items: :auto,
            )
          else
            Array(prompt_injection_items).dup + context_budget_prompt_injection_items(visible_tools: visible_tools)
          end

        prompt_context =
          PromptBuilder::Context.new(
            system_prompt: adapted.system_prompt,
            chat_history: adapted.messages,
            tools_registry: tools_registry_for_prompt(visible_tools),
            memory_results: memory_results,
            user_message: nil,
            variables: variables_from_context,
            agent_config: { llm_options: @runtime.llm_options },
            tool_policy: tool_policy_for_prompt(visible_tools),
            execution_context: @execution_context,
            skills_store: @runtime.skills_store,
            include_skill_locations: @runtime.include_skill_locations,
            prompt_mode: @runtime.prompt_mode,
            prompt_injection_items: prompt_injection_items,
            system_prompt_section_overrides: @runtime.system_prompt_section_overrides,
          )

        PromptBuilder::SimplePipeline.new.build(context: prompt_context)
      end

      private

        def lookup_memory(latest_user_message)
          store = @runtime.memory_store
          return [] if store.nil?

          query = latest_user_message&.text.to_s
          query = query.strip
          return [] if query.empty?

          limit = Integer(@runtime.memory_search_limit || 0)
          return [] if limit <= 0

          store.search(query: query, limit: limit)
        rescue StandardError
          []
        end

        def build_prompt_injection_items(latest_user_message)
          source_prompt_injection_items(latest_user_message) + lane_prompt_buffer_prompt_injection_items
        rescue StandardError
          source_prompt_injection_items(latest_user_message)
        end

        def source_prompt_injection_items(latest_user_message)
          sources = @runtime.prompt_injection_sources
          return [] if sources.empty?

          user_message = latest_user_message&.text.to_s

          sources.flat_map do |source|
            next [] unless source.respond_to?(:items)

            source.items(
              agent: nil,
              user_message: user_message,
              execution_context: @execution_context,
              prompt_mode: @runtime.prompt_mode,
            )
          end
        rescue StandardError
          []
        end

        def lane_prompt_buffer_prompt_injection_items
          lane = current_lane
          return [] if lane.nil?

          LanePromptBufferSections.new(lane: lane).prompt_injection_items
        rescue StandardError
          []
        end

        def current_lane
          lane_id = @execution_context.attributes.dig(:dag, :lane_id).to_s.strip
          return nil if lane_id.empty?

          ::DAG::Lane.includes(:lane_prompt_buffer_entries).find_by(id: lane_id)
        rescue StandardError
          nil
        end

        def variables_from_context
          attrs = @execution_context.attributes

          vars = attrs[:variables] || attrs[:prompt_variables]
          vars.is_a?(Hash) ? vars : {}
        rescue StandardError
          {}
        end

        def visible_tool_definitions
          return nil unless @runtime.tools_registry

          policy = @runtime.tool_policy || AgentCore::Resources::Tools::Policy::DenyAll.new
          tools = @runtime.tools_registry.definitions
          Array(policy.filter(tools: tools, context: @execution_context))
        rescue StandardError
          []
        end

        def tools_registry_for_prompt(visible_tools)
          return @runtime.tools_registry if visible_tools.nil?

          VisibleToolsRegistry.new(definitions_list: visible_tools)
        end

        def tool_policy_for_prompt(visible_tools)
          return @runtime.tool_policy if visible_tools.nil?

          AgentCore::Resources::Tools::Policy::AllowAll.new
        end

        def context_budget_prompt_injection_items(visible_tools:)
          payload = context_budget_prompt_payload(visible_tools: visible_tools)
          return [] unless payload

          [
            AgentCore::Resources::PromptInjections::Item.new(
              target: :system_section,
              id: "context_budget_guidance",
              order: 875,
              content: "<context_budget_guidance>\n#{JSON.generate(payload)}\n</context_budget_guidance>",
              metadata: { source: "context_budget" },
            ),
          ]
        rescue StandardError
          []
        end

        def context_budget_prompt_payload(visible_tools:)
          budget = @execution_context.attributes.fetch(:context_budget, nil)
          return nil unless budget.is_a?(Hash)
          return nil unless budget.fetch(:budget_action, budget.fetch("budget_action", nil)).to_s == "advise_compact"

          payload = {
            effective_prompt_budget_tokens: budget.fetch(:effective_prompt_budget_tokens, budget.fetch("effective_prompt_budget_tokens", nil)),
            effective_context_soft_limit_tokens: budget.fetch(:effective_context_soft_limit_tokens, budget.fetch("effective_context_soft_limit_tokens", nil)),
            estimated_tokens: budget.fetch(:estimated_tokens, budget.fetch("estimated_tokens", nil)),
            budget_state: budget.fetch(:budget_state, budget.fetch("budget_state", nil)),
            compact_context_available: compact_context_visible?(visible_tools),
          }.compact

          payload.presence
        rescue StandardError
          nil
        end

        def compact_context_visible?(visible_tools)
          Array(visible_tools).any? { |tool| tool_name_from_definition(tool) == "compact_context" }
        rescue StandardError
          false
        end

        def tool_name_from_definition(tool_def)
          return "" unless tool_def.is_a?(Hash)

          tool_def.fetch(:name, tool_def.fetch("name", tool_def.dig(:function, :name) || tool_def.dig("function", "name") || "")).to_s
        rescue StandardError
          ""
        end
    end
  end
end
