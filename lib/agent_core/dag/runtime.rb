# frozen_string_literal: true

module AgentCore
  module DAG
    Runtime =
      Data.define(
        :provider,
        :model,
        :fallback_models,
        :tools_registry,
        :tool_policy,
        :tool_name_aliases,
        :tool_name_normalize_fallback,
        :skills_store,
        :memory_store,
        :memory_search_limit,
        :tool_output_pruner,
        :prompt_injection_sources,
        :token_counter,
        :context_turns,
        :context_window_tokens,
        :reserved_output_tokens,
        :auto_compact,
        :summary_model,
        :summary_max_tokens,
        :llm_options,
        :tool_call_repair_attempts,
        :tool_call_repair_fallback_models,
        :tool_call_repair_max_output_tokens,
        :instrumenter,
        :max_tool_calls_per_turn,
        :max_steps_per_turn,
        :include_skill_locations,
        :prompt_mode,
        :tool_error_mode,
      ) do
        DEFAULT_CONTEXT_TURNS = 50
        DEFAULT_MEMORY_SEARCH_LIMIT = 5
        DEFAULT_MAX_TOOL_CALLS_PER_TURN = 20
        DEFAULT_MAX_STEPS_PER_TURN = 10

        def initialize(
          provider:,
          model:,
          fallback_models: [],
          tools_registry:,
          tool_policy: nil,
          tool_name_aliases: {},
          tool_name_normalize_fallback: false,
          skills_store: nil,
          memory_store: nil,
          memory_search_limit: DEFAULT_MEMORY_SEARCH_LIMIT,
          tool_output_pruner: AgentCore::ContextManagement::ToolOutputPruner.new,
          prompt_injection_sources: [],
          token_counter: nil,
          context_turns: DEFAULT_CONTEXT_TURNS,
          context_window_tokens: nil,
          reserved_output_tokens: 0,
          auto_compact: false,
          summary_model: nil,
          summary_max_tokens: AgentCore::ContextManagement::Summarizer::DEFAULT_MAX_OUTPUT_TOKENS,
          llm_options: {},
          tool_call_repair_attempts: 1,
          tool_call_repair_fallback_models: [],
          tool_call_repair_max_output_tokens: 300,
          instrumenter: nil,
          max_tool_calls_per_turn: DEFAULT_MAX_TOOL_CALLS_PER_TURN,
          max_steps_per_turn: DEFAULT_MAX_STEPS_PER_TURN,
          include_skill_locations: false,
          prompt_mode: :full,
          tool_error_mode: :safe
        )
          model = model.to_s.strip
          raise ArgumentError, "model is required" if model.empty?
          raise ArgumentError, "provider is required" if provider.nil?
          raise ArgumentError, "tools_registry is required" if tools_registry.nil?

          fallback_models =
            Array(fallback_models)
              .map { |m| m.to_s.strip }
              .reject(&:empty?)
              .freeze

          tool_name_aliases =
            if tool_name_aliases.nil?
              {}
            elsif tool_name_aliases.is_a?(Hash)
              tool_name_aliases
                .each_with_object({}) do |(k, v), out|
                  key = k.to_s.strip
                  val = v.to_s.strip
                  next if key.empty? || val.empty?

                  out[key] = val
                end
            else
              {}
            end
          tool_name_aliases = tool_name_aliases.freeze

          tool_name_normalize_fallback = tool_name_normalize_fallback == true

          merged_tool_name_aliases = AgentCore::Resources::Tools::ToolNameResolver.merge_aliases(tool_name_aliases)
          validate_tool_name_aliases!(tools_registry, merged_tool_name_aliases)

          if tool_name_normalize_fallback
            AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(tools_registry.tool_names)
          end

          token_counter ||= AgentCore::Resources::TokenCounter::Heuristic.new

          context_turns = Integer(context_turns)
          raise ArgumentError, "context_turns must be > 0" if context_turns <= 0

          context_window_tokens =
            if context_window_tokens.nil?
              nil
            else
              value = Integer(context_window_tokens)
              raise ArgumentError, "context_window_tokens must be > 0" if value <= 0
              value
            end

          reserved_output_tokens = Integer(reserved_output_tokens)
          raise ArgumentError, "reserved_output_tokens must be >= 0" if reserved_output_tokens.negative?

          max_tool_calls_per_turn =
            if max_tool_calls_per_turn.nil?
              nil
            else
              value = Integer(max_tool_calls_per_turn)
              raise ArgumentError, "max_tool_calls_per_turn must be > 0" if value <= 0
              value
            end

          max_steps_per_turn = Integer(max_steps_per_turn)
          raise ArgumentError, "max_steps_per_turn must be > 0" if max_steps_per_turn <= 0

          llm_options = llm_options.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(llm_options) : {}

          tool_call_repair_attempts = Integer(tool_call_repair_attempts)
          raise ArgumentError, "tool_call_repair_attempts must be >= 0" if tool_call_repair_attempts.negative?

          tool_call_repair_fallback_models =
            Array(tool_call_repair_fallback_models)
              .map { |m| m.to_s.strip }
              .reject(&:empty?)
              .freeze

          tool_call_repair_max_output_tokens = Integer(tool_call_repair_max_output_tokens)
          raise ArgumentError, "tool_call_repair_max_output_tokens must be > 0" if tool_call_repair_max_output_tokens <= 0

          instrumenter ||= AgentCore::Observability::NullInstrumenter.new

          tool_policy ||= AgentCore::Resources::Tools::Policy::DenyAll.new

          prompt_injection_sources = Array(prompt_injection_sources)

          memory_search_limit = Integer(memory_search_limit)
          raise ArgumentError, "memory_search_limit must be >= 0" if memory_search_limit.negative?

          prompt_mode = prompt_mode.to_s.strip.downcase.tr("-", "_").to_sym
          prompt_mode = :full unless AgentCore::Resources::PromptInjections::PROMPT_MODES.include?(prompt_mode)

          tool_error_mode = tool_error_mode.to_s.strip.downcase.tr("-", "_").to_sym
          tool_error_mode = :safe unless %i[safe debug].include?(tool_error_mode)

          summary_model = summary_model&.to_s&.strip
          summary_model = nil if summary_model.to_s.empty?

          super(
            provider: provider,
            model: model,
            fallback_models: fallback_models,
            tools_registry: tools_registry,
            tool_policy: tool_policy,
            tool_name_aliases: tool_name_aliases,
            tool_name_normalize_fallback: tool_name_normalize_fallback,
            skills_store: skills_store,
            memory_store: memory_store,
            memory_search_limit: memory_search_limit,
            tool_output_pruner: tool_output_pruner,
            prompt_injection_sources: prompt_injection_sources.freeze,
            token_counter: token_counter,
            context_turns: context_turns,
            context_window_tokens: context_window_tokens,
            reserved_output_tokens: reserved_output_tokens,
            auto_compact: auto_compact == true,
            summary_model: summary_model,
            summary_max_tokens: Integer(summary_max_tokens),
            llm_options: llm_options.freeze,
            tool_call_repair_attempts: tool_call_repair_attempts,
            tool_call_repair_fallback_models: tool_call_repair_fallback_models,
            tool_call_repair_max_output_tokens: tool_call_repair_max_output_tokens,
            instrumenter: instrumenter,
            max_tool_calls_per_turn: max_tool_calls_per_turn,
            max_steps_per_turn: max_steps_per_turn,
            include_skill_locations: include_skill_locations == true,
            prompt_mode: prompt_mode,
            tool_error_mode: tool_error_mode,
          )
        end

        private

        def validate_tool_name_aliases!(tools_registry, merged_aliases)
          return unless tools_registry.respond_to?(:include?)

          merged_aliases.each do |from, to|
            next unless tools_registry.include?(from)
            next if from.to_s == to.to_s

            raise ArgumentError,
                  "tool_name_aliases contains a key that is shadowed by an existing tool name: " \
                  "#{from.inspect} (maps to #{to.inspect}). " \
                  "Remove the alias or rename the tool."
          end
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError)
        end
      end
  end
end
