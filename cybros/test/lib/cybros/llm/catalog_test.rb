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

  test "loads default catalog and exposes providers" do
    cat = Cybros::LLM::Catalog.effective
    assert cat.providers.is_a?(Hash)
    assert cat.providers.key?("openai")
    assert cat.providers.key?("codex_subscription")
    assert cat.providers.key?("openrouter")
    assert cat.providers.key?("dev")
    refute cat.providers.key?("local")
  end

  test "default catalog exposes top-level default model and current provider lineup" do
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
