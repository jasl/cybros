# frozen_string_literal: true

module AgentCore
  module DAG
    class PromptAssembly
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

      def build(context_nodes:, memory_results: :auto, prompt_injection_items: :auto)
        adapted = ContextAdapter.new(context_nodes: context_nodes).call
        latest_user_message = adapted.latest_user_message

        memory_results = lookup_memory(latest_user_message) if memory_results == :auto
        memory_results = Array(memory_results)

        prompt_injection_items = build_prompt_injection_items(latest_user_message) if prompt_injection_items == :auto
        prompt_injection_items = Array(prompt_injection_items)

        prompt_context =
          PromptBuilder::Context.new(
            system_prompt: adapted.system_prompt,
            chat_history: adapted.messages,
            tools_registry: @runtime.tools_registry,
            memory_results: memory_results,
            user_message: nil,
            variables: variables_from_context,
            agent_config: { llm_options: @runtime.llm_options },
            tool_policy: @runtime.tool_policy,
            execution_context: @execution_context,
            skills_store: @runtime.skills_store,
            include_skill_locations: @runtime.include_skill_locations,
            prompt_mode: @runtime.prompt_mode,
            prompt_injection_items: prompt_injection_items,
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

        def variables_from_context
          attrs = @execution_context.attributes

          vars = attrs[:variables] || attrs[:prompt_variables]
          vars.is_a?(Hash) ? vars : {}
        rescue StandardError
          {}
        end
    end
  end
end
