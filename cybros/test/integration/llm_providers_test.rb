# frozen_string_literal: true

require "test_helper"

class LlmProvidersTest < ActionDispatch::IntegrationTest
  def with_stubbed_class_method(klass, method_name, value: nil, implementation: nil)
    original = klass.method(method_name)
    klass.define_singleton_method(method_name) do |*args, **kwargs|
      if implementation.respond_to?(:call)
        implementation.call(*args, **kwargs)
      else
        value
      end
    end
    yield
  ensure
    klass.define_singleton_method(method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def provider_models_error
    SimpleInference::Errors::HTTPError.new(
      "boom",
      response: SimpleInference::Response.new(status: 500, headers: {}, body: {}, raw_body: ""),
    )
  end

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    identity
  end

  test "requires authentication" do
    get llm_providers_path
    assert_redirected_to new_session_path
  end

  test "index lists providers" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "OpenRouter", base_url: "https://openrouter.ai/api/v1", api_key: "sk-test")

    get llm_providers_path
    assert_response :success
    assert_includes response.body, provider.name
  end

  test "create redirects to edit and stores encrypted api_key" do
    sign_in_owner!

    assert_difference -> { LLMProvider.count }, +1 do
      post llm_providers_path, params: {
        llm_provider: {
          name: "OpenRouter",
          base_url: "https://openrouter.ai/api/v1",
          api_key: "sk-test",
          api_format: "openai",
          priority: 10,
          model_allowlist: %w[gpt-4o-mini gpt-4.1-mini],
        },
      }
    end

    provider = LLMProvider.order(:created_at).last
    assert_redirected_to edit_llm_provider_path(provider)
    assert_equal "sk-test", provider.api_key

    raw =
      LLMProvider.lease_connection.select_value(
        LLMProvider.send(
          :sanitize_sql_array,
          ["SELECT api_key FROM llm_providers WHERE id = ?", provider.id],
        ),
      ).to_s
    refute_equal "sk-test", raw
    refute_includes raw, "sk-test"
  end

  test "update changes provider fields" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "P1", base_url: "http://localhost:1234/v1", api_key: nil, api_format: "openai", priority: 0, model_allowlist: [])

    patch llm_provider_path(provider), params: {
      llm_provider: {
        name: "P2",
        priority: 5,
        model_allowlist_text: "m1\nm2\nm2\n\n",
      },
    }

    assert_redirected_to edit_llm_provider_path(provider)
    provider.reload
    assert_equal "P2", provider.name
    assert_equal 5, provider.priority
    assert_equal %w[m1 m2], provider.model_allowlist
  end

  test "update returns unprocessable_entity on invalid headers_json" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "P1", base_url: "http://localhost:1234/v1", api_key: nil, api_format: "openai", priority: 0, model_allowlist: [], headers: {})

    patch llm_provider_path(provider), params: {
      llm_provider: {
        headers_json: "{",
      },
    }

    assert_response :unprocessable_entity
  end

  test "destroy removes provider" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "P1", base_url: "http://localhost:1234/v1", api_key: nil)

    assert_difference -> { LLMProvider.count }, -1 do
      delete llm_provider_path(provider)
    end

    assert_redirected_to llm_providers_path
  end

  test "fetch_models updates allowlist" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "P1", base_url: "http://localhost:1234/v1", api_key: nil, model_allowlist: [])

    with_stubbed_class_method(LLMProviders::ModelFetcher, :model_ids_for, value: ["m1", "m2"]) do
      post fetch_models_llm_provider_path(provider)
    end

    assert_redirected_to edit_llm_provider_path(provider)
    provider.reload
    assert_equal %w[m1 m2], provider.model_allowlist
  end

  test "fetch_models failure does not change allowlist" do
    sign_in_owner!
    provider = LLMProvider.create!(name: "P1", base_url: "http://localhost:1234/v1", api_key: nil, model_allowlist: ["existing"])

    with_stubbed_class_method(
      LLMProviders::ModelFetcher,
      :model_ids_for,
      implementation: ->(*) { raise provider_models_error },
    ) do
      post fetch_models_llm_provider_path(provider)
    end

    assert_redirected_to edit_llm_provider_path(provider)
    provider.reload
    assert_equal ["existing"], provider.model_allowlist
  end
end

