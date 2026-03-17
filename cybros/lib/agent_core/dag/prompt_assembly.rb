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

      def prepare(context_nodes:, excluded_prompt_buffer_names: [])
        adapted = ContextAdapter.new(context_nodes: context_nodes).call
        latest_user_message = adapted.latest_user_message

        Prepared.new(
          latest_user_message: latest_user_message,
          memory_results: lookup_memory(latest_user_message),
          prompt_injection_items: build_prompt_injection_items(
            latest_user_message,
            excluded_prompt_buffer_names: excluded_prompt_buffer_names,
          ),
        )
      end

      def final_prompt_injection_items(prompt_injection_items: :auto, latest_user_message: nil, excluded_prompt_buffer_names: [])
        base_items =
          if prompt_injection_items == :auto
            build_prompt_injection_items(
              latest_user_message,
              excluded_prompt_buffer_names: excluded_prompt_buffer_names,
            )
          else
            filter_prompt_injection_items(
              Array(prompt_injection_items),
              excluded_prompt_buffer_names: excluded_prompt_buffer_names,
            )
          end

        Array(base_items).dup + context_budget_prompt_injection_items(visible_tools: visible_tool_definitions)
      rescue StandardError
        if prompt_injection_items == :auto
          build_prompt_injection_items(
            latest_user_message,
            excluded_prompt_buffer_names: excluded_prompt_buffer_names,
          )
        else
          filter_prompt_injection_items(
            Array(prompt_injection_items),
            excluded_prompt_buffer_names: excluded_prompt_buffer_names,
          )
        end
      end

      def build(context_nodes:, memory_results: :auto, prompt_injection_items: :auto, excluded_prompt_buffer_names: [])
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
              excluded_prompt_buffer_names: excluded_prompt_buffer_names,
            )
          else
            filter_prompt_injection_items(
              Array(prompt_injection_items),
              excluded_prompt_buffer_names: excluded_prompt_buffer_names,
            ).dup + context_budget_prompt_injection_items(visible_tools: visible_tools)
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

        def build_prompt_injection_items(latest_user_message, excluded_prompt_buffer_names: [])
          source_prompt_injection_items(latest_user_message) +
            lane_prompt_buffer_prompt_injection_items(excluded_prompt_buffer_names: excluded_prompt_buffer_names)
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

        def lane_prompt_buffer_prompt_injection_items(excluded_prompt_buffer_names: [])
          lane = current_lane
          return [] if lane.nil?

          LanePromptBufferSections.new(lane: lane).prompt_injection_items(
            excluded_buffer_names: Array(excluded_prompt_buffer_names),
          )
        rescue StandardError
          []
        end

        def filter_prompt_injection_items(items, excluded_prompt_buffer_names:)
          excluded = Array(excluded_prompt_buffer_names).map { |name| name.to_s.strip }.reject(&:empty?).uniq
          return Array(items) if excluded.empty?

          Array(items).reject do |item|
            metadata =
              if item.respond_to?(:metadata) && item.metadata.is_a?(Hash)
                item.metadata
              else
                {}
              end

            metadata.fetch(:source, "").to_s == "lane_prompt_buffer" &&
              excluded.include?(metadata.fetch(:buffer_name, "").to_s)
          end
        rescue StandardError
          Array(items)
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
          visible = Array(policy.filter(tools: tools, context: @execution_context))
          visible = filter_visible_tools_by_surface(visible)
          annotate_tool_routes(visible)
        rescue AgentCore::ValidationError
          raise
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
          return nil unless budget.fetch(:budget_action, nil).to_s == "advise_compact"

          payload = {
            effective_prompt_budget_tokens: budget.fetch(:effective_prompt_budget_tokens, nil),
            effective_context_soft_limit_tokens: budget.fetch(:effective_context_soft_limit_tokens, nil),
            estimated_tokens: budget.fetch(:estimated_tokens, nil),
            budget_state: budget.fetch(:budget_state, nil),
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

          tool_def.fetch(:name, tool_def.dig(:function, :name) || "").to_s
        rescue StandardError
          ""
        end

        def annotate_tool_routes(tools)
          snapshot = capability_snapshot
          return tools unless snapshot

          Array(tools).map do |tool|
            tool_name = tool_name_from_definition(tool)
            route = snapshot.route_for!(tool_name)

            AgentCore::Utils.deep_stringify_keys(tool).merge(
              "logical_tool_name" => route.logical_tool_name,
              "effective_tool_id" => route.effective_tool_id,
              "implementation_source" => route.implementation_source,
              "implementation_ref" => route.implementation_ref,
            )
          end
        end

        def filter_visible_tools_by_surface(tools)
          manifest = tool_surface_manifest
          return tools unless manifest

          Array(tools).select do |tool|
            manifest.effective_tool_for(tool_name_from_definition(tool))
          end
        end

        def tool_surface_manifest
          return @tool_surface_manifest if defined?(@tool_surface_manifest)

          payload =
            @execution_context.attributes.dig(:cybros, :tool_surface) ||
              @execution_context.attributes.dig(:cybros, "tool_surface") ||
              @execution_context.attributes.dig("cybros", :tool_surface) ||
              @execution_context.attributes.dig("cybros", "tool_surface")
          snapshot = capability_snapshot

          @tool_surface_manifest =
            if payload.is_a?(Hash) && payload.any? && snapshot
              AgentCore::RuntimeSurface::ToolSurfaceManifest.restore(
                payload,
                capability_registry_snapshot: snapshot,
              )
            else
              nil
            end
        rescue AgentCore::ValidationError
          raise
        rescue StandardError
          @tool_surface_manifest = nil
        end

        def capability_snapshot
          return @capability_snapshot if defined?(@capability_snapshot)

          payload =
            @execution_context.attributes.dig(:cybros, :capability_snapshot) ||
              @execution_context.attributes.dig(:cybros, "capability_snapshot") ||
              @execution_context.attributes.dig("cybros", :capability_snapshot) ||
              @execution_context.attributes.dig("cybros", "capability_snapshot")

          @capability_snapshot =
            if payload.is_a?(Hash) && payload.any?
              AgentCore::RuntimeSurface::ToolRoutingSnapshot.restore(payload)
            else
              nil
            end
        rescue AgentCore::ValidationError
          raise
        rescue StandardError
          @capability_snapshot = nil
        end
    end
  end
end
