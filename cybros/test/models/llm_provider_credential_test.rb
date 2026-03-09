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
