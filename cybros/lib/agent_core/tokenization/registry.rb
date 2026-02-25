# frozen_string_literal: true

module AgentCore
  module Tokenization
    # Tokenizer registry helpers.
    #
    # AgentCore owns the registry entry format + validation. The app domain owns:
    # - model hint canonicalization
    # - tokenizer sources (SOURCES list)
    # - filesystem paths / asset locations
    module Registry
      module_function

      HF_TOKENIZER_FAMILIES = %i[hf_tokenizers huggingface_tokenizers tokenizers].freeze

      def hf_tokenizer_family?(family)
        HF_TOKENIZER_FAMILIES.include?(normalize_tokenizer_family(family))
      end

      def normalize_tokenizer_family(value)
        raw = value.to_s.strip
        raw = "tiktoken" if raw.empty?
        raw.downcase.tr("-", "_").to_sym
      rescue StandardError
        :tiktoken
      end

      # Register a tokenizer entry into a registry Hash.
      #
      # @param registry [Hash] target registry (mutated)
      # @param hint [String] model hint key (exact or fnmatch key; see TokenEstimator)
      # @param tokenizer_family [String, Symbol] :tiktoken|:hf_tokenizers|:heuristic|...
      # @param tokenizer_path [String, nil] required for hf_tokenizers families
      # @param source_hint [String, nil] optional canonical hint
      # @param source_repo [String, nil] optional HF repo name
      # @param chars_per_token [Numeric, nil] optional heuristic configuration
      # @return [Hash] registry
      def register!(
        registry,
        hint:,
        tokenizer_family:,
        tokenizer_path: nil,
        source_hint: nil,
        source_repo: nil,
        chars_per_token: nil
      )
        ValidationError.raise!(
          "registry must be a Hash",
          code: "agent_core.tokenization.registry.registry_must_be_a_hash",
          details: { value_class: registry.class.name },
        ) unless registry.is_a?(Hash)

        key = hint.to_s.strip
        ValidationError.raise!(
          "hint is required",
          code: "agent_core.tokenization.registry.hint_is_required",
        ) if key.empty?

        family = normalize_tokenizer_family(tokenizer_family)

        entry = {
          "tokenizer_family" => family.to_s,
          "source_hint" => (source_hint || key).to_s,
        }

        repo = source_repo.to_s.strip
        entry["source_repo"] = repo unless repo.empty?

        if hf_tokenizer_family?(family)
          path = tokenizer_path.to_s.strip
          ValidationError.raise!(
            "tokenizer_path is required for #{family}",
            code: "agent_core.tokenization.registry.tokenizer_path_is_required_for_family",
            details: { tokenizer_family: family.to_s },
          ) if path.empty?
          entry["tokenizer_path"] = path
        end

        if family == :heuristic && !chars_per_token.nil?
          entry["chars_per_token"] = chars_per_token
        end

        registry[key] = entry
        registry
      end

      def registry(sources:)
        Array(sources).each_with_object({}) do |source, out|
          next unless source.is_a?(Hash)

          h = AgentCore::Utils.deep_stringify_keys(source)

          register!(
            out,
            hint: h.fetch("hint"),
            tokenizer_family: h.fetch("tokenizer_family", nil),
            tokenizer_path: h.fetch("tokenizer_path", nil),
            source_hint: h.fetch("source_hint", nil),
            source_repo: h.fetch("source_repo", nil),
            chars_per_token: h.fetch("chars_per_token", nil),
          )
        end
      end
    end
  end
end
