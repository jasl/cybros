require "test_helper"

class DbSeedsTest < ActiveSupport::TestCase
  test "does not seed openrouter credential from simple inference api key" do
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => nil,
      "SIMPLE_INFERENCE_API_KEY" => "sk-simple-inference",
      "OPENAI_API_KEY" => nil,
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    assert_nil LLMProviderCredential.find_by(provider_key: "openrouter")
  end

  test "seeds openrouter credential from explicit env" do
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => "sk-openrouter-explicit",
      "SIMPLE_INFERENCE_API_KEY" => nil,
      "OPENAI_API_KEY" => nil,
      "DEFAULT_MODEL" => nil,
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    credential = LLMProviderCredential.find_by!(provider_key: "openrouter")

    assert_equal "sk-openrouter-explicit", credential.api_key
  end

  test "seeds default model from env" do
    Account.instance.update_llm_default_model_ref!("")
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => "sk-openrouter-explicit",
      "SIMPLE_INFERENCE_API_KEY" => nil,
      "OPENAI_API_KEY" => nil,
      "DEFAULT_MODEL" => "openrouter/moonshotai-kimi-k2.5-nitro",
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    assert_equal "openrouter/moonshotai-kimi-k2.5-nitro", Account.instance.reload.llm_default_model_ref
  end

  test "rejects invalid default model ref from env" do
    Account.instance.update_llm_default_model_ref!("")
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    error =
      assert_raises(AgentCore::ValidationError) do
        with_env(
          "OPENROUTER_API_KEY" => "sk-openrouter-explicit",
          "SIMPLE_INFERENCE_API_KEY" => nil,
          "OPENAI_API_KEY" => nil,
          "DEFAULT_MODEL" => "openrouter/moonshotai/kimi-k2.5:nitro",
        ) do
          load Rails.root.join("db/seeds.rb")
        end
      end

    assert_equal "cybros.llm.model_not_found", error.code
    assert_nil Account.instance.reload.llm_default_model_ref
  end

  test "rejects default model from env when provider credential is missing" do
    Account.instance.update_llm_default_model_ref!("")
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    error =
      assert_raises(AgentCore::ValidationError) do
        with_env(
          "OPENROUTER_API_KEY" => nil,
          "SIMPLE_INFERENCE_API_KEY" => nil,
          "OPENAI_API_KEY" => nil,
          "DEFAULT_MODEL" => "openrouter/moonshotai-kimi-k2.5-nitro",
        ) do
          load Rails.root.join("db/seeds.rb")
        end
      end

    assert_equal "cybros.llm.credential_missing", error.code
    assert_nil Account.instance.reload.llm_default_model_ref
  end

  test "does not overwrite default model when env is absent" do
    Account.instance.update_llm_default_model_ref!("dev/mock-model")
    LLMProviderCredential.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => nil,
      "SIMPLE_INFERENCE_API_KEY" => nil,
      "OPENAI_API_KEY" => nil,
      "DEFAULT_MODEL" => nil,
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    assert_equal "dev/mock-model", Account.instance.reload.llm_default_model_ref
  end

  private

    def with_env(values)
      original = values.to_h { |key, _value| [key, ENV[key]] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      original.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
end
