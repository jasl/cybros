require "test_helper"

class RuntimeGovernance::ProviderBudgetReservationsTest < ActiveSupport::TestCase
  test "acquires idempotently and settles provider reservations by durable request id" do
    credential = create_provider_credential!(max_concurrent_requests: 2, requests_per_minute: 10, tokens_per_minute: 1_000)

    acquired =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-1",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: SecureRandom.uuid,
      )

    duplicate =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-1",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: SecureRandom.uuid,
      )

    reservation = acquired.fetch(:reservation)
    assert_equal "acquired", acquired.fetch(:decision)
    assert_equal reservation.id, duplicate.fetch(:reservation).id
    assert_equal 1, ProviderBudgetReservation.count

    settled =
      RuntimeGovernance::ProviderBudgetReservations.settle!(
        provider_credential: credential,
        provider_request_id: "provider-req-1",
        actual_tokens: 64,
      )

    assert_equal "settled", settled.status
    assert_equal 64, settled.actual_tokens
  end

  test "parks work when active provider reservations exhaust concurrent budget" do
    credential = create_provider_credential!(max_concurrent_requests: 1, requests_per_minute: 10, tokens_per_minute: 1_000)

    RuntimeGovernance::ProviderBudgetReservations.acquire!(
      provider_credential: credential,
      provider_request_id: "provider-req-1",
      request_units: 1,
      estimated_tokens: 80,
      owner_type: "RunDraft",
      owner_id: "draft-1",
    )

    blocked =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-2",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: "draft-2",
      )

    assert_equal "parked", blocked.fetch(:decision)
    wait = blocked.fetch(:runtime_wait)
    assert_equal "provider_limit", wait.reason_type
    assert_equal "llm_provider_credential", wait.subject_type
    assert_equal credential.id, wait.subject_id
  end

  test "counts request_units when enforcing concurrent provider budget" do
    credential = create_provider_credential!(max_concurrent_requests: 2, requests_per_minute: 10, tokens_per_minute: 1_000)

    RuntimeGovernance::ProviderBudgetReservations.acquire!(
      provider_credential: credential,
      provider_request_id: "provider-req-1",
      request_units: 2,
      estimated_tokens: 80,
      owner_type: "RunDraft",
      owner_id: "draft-1",
    )

    blocked =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-2",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: "draft-2",
      )

    assert_equal "parked", blocked.fetch(:decision)
  end

  test "parks work when settled requests exhaust the rolling provider request budget" do
    credential = create_provider_credential!(max_concurrent_requests: 4, requests_per_minute: 1, tokens_per_minute: 1_000)
    now = Time.current.change(usec: 0)

    RuntimeGovernance::ProviderBudgetReservations.acquire!(
      provider_credential: credential,
      provider_request_id: "provider-req-1",
      request_units: 1,
      estimated_tokens: 80,
      owner_type: "RunDraft",
      owner_id: "draft-1",
      now: now,
    )
    RuntimeGovernance::ProviderBudgetReservations.settle!(
      provider_credential: credential,
      provider_request_id: "provider-req-1",
      actual_tokens: 64,
      now: now + 5.seconds,
    )

    blocked =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-2",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: "draft-2",
        now: now + 10.seconds,
      )

    assert_equal "parked", blocked.fetch(:decision)
    assert_equal "provider_limit", blocked.fetch(:runtime_wait).reason_type
  end

  test "reconciles expired reservations so new work can acquire" do
    credential = create_provider_credential!(max_concurrent_requests: 1, requests_per_minute: 10, tokens_per_minute: 1_000)
    stale =
      ProviderBudgetReservation.create!(
        provider_credential: credential,
        provider_request_id: "provider-req-stale",
        request_units: 1,
        estimated_tokens: 80,
        reserved_until: 1.minute.ago,
        status: "active",
        reconciliation_metadata: {},
      )

    count = RuntimeGovernance::ProviderBudgetReservations.reconcile_expired!(provider_credential: credential, now: Time.current)

    assert_equal 1, count
    assert_equal "expired", stale.reload.status

    acquired =
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: credential,
        provider_request_id: "provider-req-2",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: "draft-2",
      )

    assert_equal "acquired", acquired.fetch(:decision)
  end

  private

  def create_provider_credential!(attributes = {})
    LLMProviderCredential.create!(
      {
        provider_key: "openai",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 2,
        requests_per_minute: 60,
        tokens_per_minute: 120_000,
        burst_limit: 8,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
      }.merge(attributes),
    )
  end
end
