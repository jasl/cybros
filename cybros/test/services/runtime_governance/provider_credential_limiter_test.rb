require "test_helper"

class RuntimeGovernance::ProviderCredentialLimiterTest < ActiveSupport::TestCase
  test "resolves the active provider credential and limiter snapshot for the selected model" do
    credential =
      LLMProviderCredential.create!(
        provider_key: "openai",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 3,
        requests_per_minute: 90,
        tokens_per_minute: 180_000,
        burst_limit: 6,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      )

    resolved = RuntimeGovernance::ProviderCredentialLimiter.resolve!(selected_model_ref: "openai/gpt-5.4")

    assert_equal credential, resolved.fetch(:provider_credential)
    assert_equal(
      {
        "provider_key" => "openai",
        "provider_credential_id" => credential.id,
        "credential_type" => "api_key",
        "max_concurrent_requests" => 3,
        "requests_per_minute" => 90,
        "tokens_per_minute" => 180_000,
        "burst_limit" => 6,
        "backoff_policy" => { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      },
      resolved.fetch(:snapshot),
    )
  end

  test "rejects selected models whose provider has no active credential" do
    LLMProviderCredential.create!(
      provider_key: "openai",
      credential_type: "api_key",
      status: "inactive",
      api_key: "sk-test",
    )

    error =
      assert_raises(AgentCore::ValidationError) do
        RuntimeGovernance::ProviderCredentialLimiter.resolve!(selected_model_ref: "openai/gpt-5.4")
      end

    assert_equal "cybros.runtime_governance.provider_credential_missing", error.code
    assert_equal({ provider_key: "openai" }, error.details)
  end
end
