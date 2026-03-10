require "test_helper"

class DbSeedsTest < ActiveSupport::TestCase
  test "seeds openrouter credential from simple inference api key when explicit openrouter key is absent" do
    LLMProvider.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => nil,
      "SIMPLE_INFERENCE_API_KEY" => "sk-simple-inference",
      "OPENAI_API_KEY" => nil,
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    credential = LLMProvider.find_by!(provider_key: "openrouter")

    assert_equal "api_key", credential.credential_type
    assert_equal "sk-simple-inference", credential.api_key
  end

  test "seeds openrouter credential from explicit env before simple inference fallback" do
    LLMProvider.where(provider_key: "openrouter").delete_all

    with_env(
      "OPENROUTER_API_KEY" => "sk-openrouter-explicit",
      "SIMPLE_INFERENCE_API_KEY" => "sk-simple-inference",
      "OPENAI_API_KEY" => nil,
    ) do
      load Rails.root.join("db/seeds.rb")
    end

    credential = LLMProvider.find_by!(provider_key: "openrouter")

    assert_equal "sk-openrouter-explicit", credential.api_key
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
