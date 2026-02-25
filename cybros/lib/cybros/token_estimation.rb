# frozen_string_literal: true

require "pathname"

module Cybros
  # App-owned token estimation registry and model hint canonicalization.
  #
  # AgentCore::Tokenization::Registry only validates registry entries; Cybros owns:
  # - SOURCES (model hints + HF repos)
  # - tokenizer asset paths
  # - provider-specific model ID canonicalization
  module TokenEstimation
    TOKENIZER_ROOT_ENV_KEY = "CYBROS_TOKENIZER_ROOT"

    ESTIMATOR_MUTEX = Mutex.new

    SOURCES = [
      {
        hint: "deepseek-v3",
        hf_repo: "deepseek-ai/DeepSeek-V3-0324",
      },
      {
        hint: "deepseek-v3.2",
        hf_repo: "deepseek-ai/DeepSeek-V3.2",
      },
      {
        hint: "qwen3",
        hf_repo: "Qwen/Qwen3-30B-A3B-Instruct-2507",
      },
      {
        hint: "qwen3-30b-a3b-instruct",
        hf_repo: "Qwen/Qwen3-30B-A3B-Instruct-2507",
      },
      {
        hint: "qwen3-next-80b-a3b-instruct",
        hf_repo: "Qwen/Qwen3-Next-80B-A3B-Instruct",
      },
      {
        hint: "qwen3-235b-a22b-instruct-2507",
        hf_repo: "Qwen/Qwen3-235B-A22B-Instruct-2507",
      },
      {
        hint: "glm-4.7",
        hf_repo: "zai-org/GLM-4.7",
      },
      {
        hint: "glm-5",
        hf_repo: "zai-org/GLM-5",
      },
      {
        hint: "glm-4.7-flash",
        hf_repo: "zai-org/GLM-4.7-Flash",
      },
      {
        hint: "kimi-k2.5",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "gpt-5.2",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "gpt-5.2-chat",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "x-ai/grok-4.1-fast",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "anthropic/claude-opus-4.6",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "google/gemini-2.5-flash",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "google/gemini-3-flash-preview",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "google/gemini-3-pro-preview",
        tokenizer_family: :tiktoken,
      },
      {
        hint: "minimax-m2.1",
        hf_repo: "MiniMaxAI/MiniMax-M2.1",
      },
      {
        hint: "minimax-m2.5",
        hf_repo: "MiniMaxAI/MiniMax-M2.5",
      },
    ].freeze

    module_function

    def canonical_model_hint(model_id)
      base = model_id.to_s.strip
      base = base.split(":", 2).first.to_s
      token = base.downcase

      if token.start_with?("openai/")
        # Prefer the OpenAI model name (helps tiktoken encoding selection).
        return base.split("/", 2).last.to_s
      end

      return "deepseek-v3.2" if token.include?("deepseek-v3.2")
      return "deepseek-v3" if token.include?("deepseek-chat-v3-0324") || token.include?("deepseek-v3-0324")
      return "deepseek-v3.2" if token.include?("deepseek")

      return "qwen3-next-80b-a3b-instruct" if token.include?("qwen3-next-80b-a3b-instruct")
      return "qwen3-235b-a22b-instruct-2507" if token.include?("qwen3-235b-a22b")
      return "qwen3-30b-a3b-instruct" if token.include?("qwen3-30b-a3b-instruct")
      return "qwen3" if token.include?("qwen3")

      return "glm-5" if token.include?("glm-5")
      return "glm-4.7-flash" if token.include?("glm-4.7-flash")
      return "glm-4.7" if token.include?("glm-4.7")
      return "kimi-k2.5" if token.include?("kimi-k2.5")
      return "minimax-m2.5" if token.include?("minimax-m2.5")
      return "minimax-m2.1" if token.include?("minimax-m2")

      base
    end

    def sources
      SOURCES.map(&:dup)
    end

    def registry(tokenizer_root_path: tokenizer_root, strict: false)
      root_dir = Pathname.new(tokenizer_root_path.to_s).cleanpath

      entries =
        sources.filter_map do |source|
          hint = source.fetch(:hint, "").to_s.strip
          next if hint.empty?

          family =
            if source.key?(:tokenizer_family)
              source.fetch(:tokenizer_family)
            elsif source.key?(:hf_repo)
              :hf_tokenizers
            else
              :tiktoken
            end

          family = AgentCore::Tokenization::Registry.normalize_tokenizer_family(family)

          entry = {
            hint: hint,
            tokenizer_family: family,
            source_hint: hint,
            source_repo: source.fetch(:hf_repo, nil),
          }

          if AgentCore::Tokenization::Registry.hf_tokenizer_family?(family)
            path = root_dir.join(tokenizer_relative_path(hint)).to_s

            if File.file?(path)
              entry[:tokenizer_path] = path
            elsif strict == true
              AgentCore::ValidationError.raise!(
                "Tokenizer file is missing: #{path}",
                code: "cybros.token_estimation.tokenizer_file_is_missing",
                details: { tokenizer_path: path, hint: hint, tokenizer_family: family.to_s },
              )
            else
              next
            end
          end

          entry
        end

      AgentCore::Tokenization::Registry.registry(sources: entries)
    end

    def estimator(tokenizer_root_path: tokenizer_root, strict: false)
      root = Pathname.new(tokenizer_root_path.to_s).cleanpath.to_s
      cache_key = "#{root}|#{strict ? "strict" : "skip_missing"}"

      ESTIMATOR_MUTEX.synchronize do
        @estimators ||= {}
        @estimators[cache_key] ||=
          AgentCore::Tokenization::TokenEstimator.new(
            registry: registry(tokenizer_root_path: root, strict: strict),
          )
      end
    end

    def tokenizer_relative_path(hint)
      File.join(hint.to_s, "tokenizer.json")
    end

    def tokenizer_root
      root = app_root

      configured = ENV.fetch(TOKENIZER_ROOT_ENV_KEY, nil)
      return root.join("vendor", "tokenizers").to_s if configured.to_s.strip.empty?

      path = Pathname.new(configured.to_s)
      path = root.join(path) if path.relative?
      path.cleanpath.to_s
    end

    def app_root
      if defined?(Rails) && Rails.respond_to?(:root)
        Pathname.new(Rails.root.to_s)
      else
        Pathname.new(Dir.pwd)
      end
    rescue StandardError
      Pathname.new(Dir.pwd)
    end
    private_class_method :app_root
  end
end
