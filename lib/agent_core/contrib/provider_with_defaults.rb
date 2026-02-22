# frozen_string_literal: true

module AgentCore
  module Contrib
    class ProviderWithDefaults < AgentCore::Resources::Provider::Base
      def initialize(provider:, request_defaults:)
        @provider = provider
        @request_defaults = normalize_request_defaults(request_defaults).freeze
      end

      def name
        @provider.name
      end

      def models
        @provider.models
      end

      def chat(messages:, model:, tools: nil, stream: false, **options)
        call_options = canonicalize_stop_keys(options.dup)
        merged_options = @request_defaults.merge(call_options)
        @provider.chat(messages: messages, model: model, tools: tools, stream: stream, **merged_options)
      end

      private

      def normalize_request_defaults(value)
        h = value.nil? ? {} : value
        ValidationError.raise!(
          "request_defaults must be a Hash",
          code: "agent_core.contrib.provider_with_defaults.request_defaults_must_be_a_hash",
          details: { value_class: h.class.name },
        ) unless h.is_a?(Hash)

        normalized = AgentCore::Utils.deep_symbolize_keys(h)
        AgentCore::Utils.assert_symbol_keys!(normalized, path: "request_defaults")

        reserved = normalized.keys & AgentCore::Contrib::OpenAI::RESERVED_CHAT_COMPLETIONS_KEYS
        if reserved.any?
          ValidationError.raise!(
            "request_defaults contains reserved keys: #{reserved.map(&:to_s).sort.inspect}",
            code: "agent_core.contrib.provider_with_defaults.request_defaults_contains_reserved_keys",
            details: { reserved_keys: reserved.map(&:to_s).sort },
          )
        end

        canonicalize_stop_keys(normalized)
      end

      def canonicalize_stop_keys(hash)
        return hash unless hash.is_a?(Hash)
        return hash unless hash.key?(:stop_sequences)

        hash[:stop] = hash[:stop_sequences] unless hash.key?(:stop)
        hash.delete(:stop_sequences)
        hash
      end
    end
  end
end
