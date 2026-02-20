# frozen_string_literal: true

module AgentCore
  module Contrib
    module LanguagePolicy
      module FinalRewriter
        DEFAULT_MAX_INPUT_BYTES = 200_000

        module_function

        def rewrite(
          provider:,
          model:,
          text:,
          llm_options: {},
          target_lang:,
          style_hint: nil,
          special_tags: [],
          token_counter: nil,
          context_window: nil,
          reserved_output_tokens: 0
        )
          lang = AgentCore::Contrib::LanguagePolicy::Detector.canonical_target_lang(target_lang)
          raise ArgumentError, "target_lang is required" if lang.empty?

          input = text.to_s
          return input if input.bytesize > DEFAULT_MAX_INPUT_BYTES
          if AgentCore::Contrib::LanguagePolicy::Detector.language_shape(input, target_lang: lang) == :ok
            return input
          end

          system_text =
            [
              AgentCore::Contrib::LanguagePolicyPrompt.build(
                lang,
                style_hint: style_hint,
                special_tags: special_tags,
                tool_calls_rule: false,
              ),
              "Rewrite the user's text into #{lang}. Output the rewritten text only.",
            ].join("\n\n")

          options = normalize_llm_options(llm_options)
          options[:temperature] = 0 unless options.key?(:temperature)

          prompt =
            AgentCore::PromptBuilder::BuiltPrompt.new(
              system_prompt: system_text,
              messages: [AgentCore::Message.new(role: :user, content: input)],
              tools: [],
              options: options,
            )

          assert_prompt_within_context_window!(
            prompt,
            token_counter: token_counter,
            context_window: context_window,
            reserved_output_tokens: reserved_output_tokens,
          )

          messages = []
          messages << AgentCore::Message.new(role: :system, content: system_text) unless system_text.to_s.strip.empty?
          messages << AgentCore::Message.new(role: :user, content: input)

          response =
            provider.chat(
              messages: messages,
              model: model.to_s,
              tools: nil,
              stream: false,
              **options
            )

          response&.message&.text.to_s
        end

        def normalize_llm_options(value)
          h = value.nil? ? {} : value
          raise ArgumentError, "llm_options must be a Hash" unless h.is_a?(Hash)

          normalized = AgentCore::Utils.deep_symbolize_keys(h)
          AgentCore::Utils.assert_symbol_keys!(normalized, path: "llm_options")

          reserved = normalized.keys & AgentCore::Contrib::OpenAI::RESERVED_CHAT_COMPLETIONS_KEYS
          if reserved.any?
            raise ArgumentError, "llm_options contains reserved keys: #{reserved.map(&:to_s).sort.inspect}"
          end

          normalized
        end
        private_class_method :normalize_llm_options

        def assert_prompt_within_context_window!(built_prompt, token_counter:, context_window:, reserved_output_tokens:)
          return if token_counter.nil? || context_window.nil?

          window = Integer(context_window, exception: false)
          return if window.nil? || window <= 0

          reserved = Integer(reserved_output_tokens, exception: false) || 0
          reserved = 0 if reserved.negative?

          limit = window - reserved
          limit = 0 if limit.negative?

          estimate = built_prompt.estimate_tokens(token_counter: token_counter)
          total = estimate.fetch(:total)

          return if total <= limit

          raise AgentCore::ContextWindowExceededError.new(
            "Estimated #{total} prompt tokens exceeds limit #{limit}",
            estimated_tokens: total,
            message_tokens: estimate.fetch(:messages),
            tool_tokens: estimate.fetch(:tools),
            context_window: window,
            reserved_output: reserved,
            limit: limit,
          )
        end
        private_class_method :assert_prompt_within_context_window!
      end
    end
  end
end
