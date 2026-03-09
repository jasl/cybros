require "test_helper"

class SystemSettingsLlmProviderGovernanceIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    LLMProvider.delete_all
  end

  test "owner can update limiter fields for api key providers" do
    sign_in_as!(role: :owner)

    patch system_settings_llm_provider_path("openai"), params: {
      llm_provider: {
        api_key: "sk-governed",
        max_concurrent_requests: "7",
        requests_per_minute: "210",
        tokens_per_minute: "450000",
        burst_limit: "11",
        backoff_policy_json: <<~JSON,
          {"kind":"exponential","base_delay_ms":750,"max_delay_ms":45000}
        JSON
      },
    }

    assert_redirected_to edit_system_settings_llm_provider_path("openai")

    provider = LLMProvider.find_by!(provider_key: "openai")
    assert_equal "api_key", provider.credential_type
    assert_equal "sk-governed", provider.api_key
    assert_equal 7, provider.max_concurrent_requests
    assert_equal 210, provider.requests_per_minute
    assert_equal 450_000, provider.tokens_per_minute
    assert_equal 11, provider.burst_limit
    assert_equal({ "kind" => "exponential", "base_delay_ms" => 750, "max_delay_ms" => 45_000 }, provider.backoff_policy)
  end

  test "owner can update api key limiter settings without replacing an existing key" do
    sign_in_as!(role: :owner)
    ensure_llm_provider!(
      provider_key: "openai",
      credential_type: "api_key",
      api_key: "sk-existing",
      max_concurrent_requests: 4,
      requests_per_minute: 120,
      tokens_per_minute: 240_000,
      burst_limit: 8,
      backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
    )

    patch system_settings_llm_provider_path("openai"), params: {
      llm_provider: {
        api_key: "",
        max_concurrent_requests: "6",
        requests_per_minute: "180",
        tokens_per_minute: "300000",
        burst_limit: "10",
        backoff_policy_json: <<~JSON,
          {"kind":"exponential","base_delay_ms":900,"max_delay_ms":60000}
        JSON
      },
    }

    assert_redirected_to edit_system_settings_llm_provider_path("openai")

    provider = LLMProvider.find_by!(provider_key: "openai")
    assert_equal "sk-existing", provider.api_key
    assert_equal 6, provider.max_concurrent_requests
    assert_equal 180, provider.requests_per_minute
    assert_equal 300_000, provider.tokens_per_minute
    assert_equal 10, provider.burst_limit
  end

  test "admin can update limiter fields for oauth providers without replacing tokens" do
    sign_in_as!(role: :admin)
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 2.hours.from_now,
      max_concurrent_requests: 4,
      requests_per_minute: 120,
      tokens_per_minute: 240_000,
      burst_limit: 8,
      backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
    )

    patch system_settings_llm_provider_path("codex_subscription"), params: {
      llm_provider: {
        max_concurrent_requests: "3",
        requests_per_minute: "75",
        tokens_per_minute: "150000",
        burst_limit: "5",
        backoff_policy_json: <<~JSON,
          {"kind":"linear","base_delay_ms":1000,"max_delay_ms":12000}
        JSON
      },
    }

    assert_redirected_to edit_system_settings_llm_provider_path("codex_subscription")

    provider = LLMProvider.find_by!(provider_key: "codex_subscription")
    assert_equal "oauth_codex", provider.credential_type
    assert_equal "access-token", provider.access_token
    assert_equal "refresh-token", provider.refresh_token
    assert_equal 3, provider.max_concurrent_requests
    assert_equal 75, provider.requests_per_minute
    assert_equal 150_000, provider.tokens_per_minute
    assert_equal 5, provider.burst_limit
    assert_equal({ "kind" => "linear", "base_delay_ms" => 1000, "max_delay_ms" => 12_000 }, provider.backoff_policy)
  end

  test "update rerenders edit when backoff policy is not a json object" do
    sign_in_as!(role: :owner)

    patch system_settings_llm_provider_path("openai"), params: {
      llm_provider: {
        api_key: "sk-governed",
        max_concurrent_requests: "9",
        requests_per_minute: "300",
        tokens_per_minute: "500000",
        burst_limit: "12",
        backoff_policy_json: "[1,2,3]",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Backoff policy must be a JSON object"
    assert_includes response.body, 'value="9"'
    assert_includes response.body, "[1,2,3]"
    assert_nil LLMProvider.find_by(provider_key: "openai")
  end

  test "member cannot update provider governance" do
    sign_in_as!(role: :member)

    patch system_settings_llm_provider_path("openai"), params: {
      llm_provider: {
        api_key: "sk-nope",
        max_concurrent_requests: "7",
        requests_per_minute: "210",
        tokens_per_minute: "450000",
        burst_limit: "11",
        backoff_policy_json: "{\"kind\":\"exponential\",\"base_delay_ms\":750,\"max_delay_ms\":45000}",
      },
    }

    assert_response :forbidden
    assert_nil LLMProvider.find_by(provider_key: "openai")
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?

      user
    end
end
