require "test_helper"
require "tmpdir"

class Cybros::LLM::CatalogTest < ActiveSupport::TestCase
  def with_env(values)
    prior = {}
    values.each do |key, value|
      prior[key] = ENV[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    Cybros::LLM::Catalog.reload!
    yield
  ensure
    prior.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    Cybros::LLM::Catalog.reload!
  end

  def with_catalog_yaml(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "providers.test.yml")
      File.write(path, yaml)

      singleton = Cybros::LLM::Catalog.singleton_class
      singleton.alias_method :__catalog_test_original_resolve_sources, :resolve_sources
      singleton.define_method(:resolve_sources) { [path] }

      begin
        Cybros::LLM::Catalog.reload!
        yield
      ensure
        singleton.alias_method :resolve_sources, :__catalog_test_original_resolve_sources
        singleton.remove_method :__catalog_test_original_resolve_sources
        Cybros::LLM::Catalog.reload!
      end
    end
  end

  test "loads default catalog and exposes providers" do
    cat = Cybros::LLM::Catalog.effective
    assert cat.providers.is_a?(Hash)
    assert cat.providers.key?("openai")
    assert cat.providers.key?("codex_subscription")
    assert cat.providers.key?("openrouter")
    assert cat.providers.key?("dev")
    refute cat.providers.key?("local")
  end

  test "catalog exposes top-level default model and provider lineup from injected config" do
    with_catalog_yaml(
      <<~YAML
        version: 1
        default_model_ref: "openai/gpt-5.4"
        providers:
          openai:
            display_name: "OpenAI"
            enabled: true
            adapter_key: "openai"
            base_url: "https://api.openai.test"
            headers: {}
            requires_credential: true
            credential_type: "api_key"
            wire_api: "responses"
            transport: "http_sse"
            responses_path: "/v1/responses"
            models:
              gpt-5.3-instant:
                display_name: "GPT‑5.3 Instant"
                api_model: "gpt-5.3-instant"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              gpt-5.4:
                display_name: "GPT‑5.4"
                api_model: "gpt-5.4"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
          codex_subscription:
            display_name: "Codex"
            enabled: true
            adapter_key: "openai"
            base_url: "https://chatgpt.com/backend-api/codex"
            headers: {}
            requires_credential: false
            wire_api: "responses"
            transport: "http_sse"
            responses_path: "/v1/responses"
            models:
              gpt-5.3-codex:
                display_name: "GPT‑5.3 Codex"
                api_model: "gpt-5.3-codex"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              gpt-5.4:
                display_name: "GPT‑5.4 Codex"
                api_model: "gpt-5.4"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              gpt-5.4-extra-high:
                display_name: "GPT‑5.4 Extra High"
                api_model: "gpt-5.4"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
                request_defaults:
                  reasoning_effort: "xhigh"
          openrouter:
            display_name: "OpenRouter"
            enabled: true
            adapter_key: "openai"
            base_url: "https://openrouter.ai/api"
            headers: {}
            requires_credential: true
            credential_type: "api_key"
            wire_api: "responses"
            transport: "http_sse"
            responses_path: "/v1/responses"
            models:
              openai-gpt-5.4-pro:
                display_name: "GPT‑5.4 Pro"
                api_model: "openai/gpt-5.4-pro"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              openai-gpt-5.3-chat:
                display_name: "GPT‑5.3 Chat"
                api_model: "openai/gpt-5.3-chat"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              anthropic-claude-opus-4.6-nitro:
                display_name: "Claude Opus 4.6 Nitro"
                api_model: "anthropic/claude-opus-4.6:nitro"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              z-ai-glm-5-nitro:
                display_name: "GLM-5 Nitro"
                api_model: "z-ai/glm-5:nitro"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
              qwen-qwen3.5-plus-02-15:
                display_name: "Qwen 3.5 Plus"
                api_model: "qwen/qwen3.5-plus-02-15"
                context_window_tokens: 200000
                capabilities: { protocol: "responses", tools: { tool_calling: true } }
          dev:
            display_name: "Dev"
            enabled: true
            adapter_key: "openai"
            base_url: "http://localhost:3000/mock_llm/v1"
            headers: {}
            requires_credential: false
            wire_api: "chat_completions"
            transport: "http"
            models:
              mock-model:
                display_name: "Mock"
                api_model: "mock-model"
                context_window_tokens: 32000
                capabilities: { protocol: "chat_completions", tools: { tool_calling: true } }
      YAML
    ) do
      cat = Cybros::LLM::Catalog.effective

      assert_equal "openai/gpt-5.4", cat.default_model_ref
      assert cat.model("openai", "gpt-5.3-instant")
      assert cat.model("openai", "gpt-5.4")
      assert_equal "GPT‑5.4", cat.model("openai", "gpt-5.4").fetch("display_name")
      refute cat.provider("openai").key?("default_model")

      assert cat.model("codex_subscription", "gpt-5.3-codex")
      assert cat.model("codex_subscription", "gpt-5.4")
      assert cat.model("codex_subscription", "gpt-5.4-extra-high")
      assert_equal "GPT‑5.4 Codex", cat.model("codex_subscription", "gpt-5.4").fetch("display_name")
      assert_equal true, cat.model("codex_subscription", "gpt-5.4").dig("capabilities", "tools", "tool_calling")
      assert_equal "xhigh", cat.model("codex_subscription", "gpt-5.4-extra-high").dig("request_defaults", "reasoning_effort")

      assert_equal "openai/gpt-5.4-pro", cat.model("openrouter", "openai-gpt-5.4-pro").fetch("api_model")
      assert_equal "openai/gpt-5.3-chat", cat.model("openrouter", "openai-gpt-5.3-chat").fetch("api_model")
      assert_equal "anthropic/claude-opus-4.6:nitro", cat.model("openrouter", "anthropic-claude-opus-4.6-nitro").fetch("api_model")
      assert_equal "z-ai/glm-5:nitro", cat.model("openrouter", "z-ai-glm-5-nitro").fetch("api_model")
      assert_equal "qwen/qwen3.5-plus-02-15", cat.model("openrouter", "qwen-qwen3.5-plus-02-15").fetch("api_model")
      assert_equal true, cat.model("openrouter", "openai-gpt-5.4-pro").dig("capabilities", "tools", "tool_calling")

      assert_equal "mock-model", cat.model("dev", "mock-model").fetch("api_model")
    end
  end

  test "environment scoping hides dev provider in production" do
    cat = Cybros::LLM::Catalog.effective
    prod = cat.enabled_provider_keys_for_env("production")
    refute_includes prod, "dev"
  end

  test "deep-merges override file via CYBROS_LLM_CONFIG_PATH" do
    Dir.mktmpdir do |dir|
      override_path = File.join(dir, "providers.override.yml")
      File.write(
        override_path,
        <<~YAML
          version: 1
          default_model_ref: "openrouter/openai-gpt-5.4"
          providers:
            openai:
              headers:
                X-Test: "1"
              models:
                gpt-5.4:
                  context_window_tokens: 999
        YAML
      )

      with_env("CYBROS_LLM_CONFIG_PATH" => override_path, "CYBROS_CONFIG_ROOT" => nil) do
        cat = Cybros::LLM::Catalog.effective
        openai = cat.provider("openai")
        assert_equal "openrouter/openai-gpt-5.4", cat.default_model_ref
        assert_equal "1", openai.dig("headers", "X-Test")
        assert_equal 999, cat.model("openai", "gpt-5.4").fetch("context_window_tokens")
      end
    end
  end

  test "catalog invariant: every non-dev model is tool-callable" do
    cat = Cybros::LLM::Catalog.effective

    cat.providers.each do |provider_key, provider_spec|
      next if provider_key.to_s == "dev"

      models = provider_spec.fetch("models", {})
      models.each do |model_key, model_spec|
        tool_calling = model_spec.dig("capabilities", "tools", "tool_calling")
        assert_equal true, tool_calling, "#{provider_key}/#{model_key} must have tools.tool_calling: true"
      end
    end
  end

  test "raises a helpful error on version mismatch" do
    Dir.mktmpdir do |dir|
      override_path = File.join(dir, "providers.override.yml")
      File.write(
        override_path,
        <<~YAML
          version: 2
          providers: {}
        YAML
      )

      err =
        assert_raises(Cybros::LLM::CatalogError) do
          with_env("CYBROS_LLM_CONFIG_PATH" => override_path, "CYBROS_CONFIG_ROOT" => nil) do
            Cybros::LLM::Catalog.effective
          end
        end
      assert_includes err.message, "$.version"
    end
  end
end
