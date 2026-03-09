require "test_helper"

class LLMProviderCredentialTest < ActiveSupport::TestCase
  test "requires limiter fields on active credentials" do
    credential =
      build_credential(
        max_concurrent_requests: nil,
        requests_per_minute: nil,
        tokens_per_minute: nil,
        burst_limit: nil,
        backoff_policy: nil,
      )

    refute_predicate credential, :valid?
    assert_includes credential.errors[:max_concurrent_requests], "can't be blank"
    assert_includes credential.errors[:requests_per_minute], "can't be blank"
    assert_includes credential.errors[:tokens_per_minute], "can't be blank"
    assert_includes credential.errors[:burst_limit], "can't be blank"
    assert_includes credential.errors[:backoff_policy], "can't be blank"
  end

  test "allows only one active credential per provider key" do
    build_credential.save!

    duplicate_active = build_credential(api_key: "sk-other")

    refute_predicate duplicate_active, :valid?
    assert_includes duplicate_active.errors[:provider_key], "has already been taken"

    inactive_duplicate = build_credential(status: "inactive", api_key: "sk-other")

    assert_predicate inactive_duplicate, :valid?
  end

  test "provides limiter defaults for new credentials" do
    credential = LLMProviderCredential.new(provider_key: "openai", credential_type: "api_key")

    assert_equal 4, credential.max_concurrent_requests
    assert_equal 120, credential.requests_per_minute
    assert_equal 240_000, credential.tokens_per_minute
    assert_equal 8, credential.burst_limit
    assert_equal({ "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 }, credential.backoff_policy)
  end

  private

  def build_credential(attributes = {})
    LLMProviderCredential.new(
      {
        provider_key: "openai",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 4,
        requests_per_minute: 120,
        tokens_per_minute: 240_000,
        burst_limit: 8,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500 },
      }.merge(attributes),
    )
  end
end
