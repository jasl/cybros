require "test_helper"
require "simple_inference"

class AgentCore::Resources::Provider::RateLimitEnforcementTest < ActiveSupport::TestCase
  class StubAdapter < SimpleInference::HTTPAdapter
    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    attr_reader :calls

    def call(request)
      @calls << request
      @handler.call(request)
    end
  end

  def test_chat_settles_provider_budget_reservation_after_a_successful_sync_call
    credential = create_provider_credential!(max_concurrent_requests: 1)
    adapter =
      StubAdapter.new do |_req|
        body = {
          "choices" => [
            {
              "message" => { "role" => "assistant", "content" => "Hello" },
              "finish_reason" => "stop",
            },
          ],
          "usage" => { "prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5 },
        }

        { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
      end
    provider = build_provider(adapter: adapter)

    response =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "hi")],
        model: "test-model",
        stream: false,
        runtime_governance: governance_options(credential: credential, owner_id: "draft-1"),
      )

    assert_equal "Hello", response.message.text
    assert_equal 1, adapter.calls.length

    reservation = ProviderBudgetReservation.find_by!(provider_credential: credential)
    assert_equal "settled", reservation.status
    assert_equal 5, reservation.actual_tokens
    assert_equal "turn-1:1", reservation.provider_request_id
  end

  def test_chat_raises_runtime_wait_error_without_calling_the_remote_provider_when_budget_is_exhausted
    credential = create_provider_credential!(max_concurrent_requests: 1)
    trace = AgentCore::Observability::TraceRecorder.new(capture: :safe)
    adapter =
      StubAdapter.new do |_req|
        raise "remote provider should not be called while blocked"
      end
    provider = build_provider(adapter: adapter)

    RuntimeGovernance::ProviderBudgetReservations.acquire!(
      provider_credential: credential,
      provider_request_id: "existing",
      request_units: 1,
      estimated_tokens: 10,
      owner_type: "RunDraft",
      owner_id: "draft-existing",
    )

    error =
      assert_raises(AgentCore::RuntimeWaitError) do
        provider.chat(
          messages: [AgentCore::Message.new(role: :user, content: "hi")],
          model: "test-model",
          stream: false,
          runtime_governance: governance_options(credential: credential, owner_id: "draft-2", instrumenter: trace),
        )
      end

    assert_equal "provider_limit", error.reason_type
    assert_equal 0, adapter.calls.length
    assert_equal 1, RuntimeWait.where(reason_type: "provider_limit", subject_id: credential.id).count
    assert_includes trace.events.map { |event| event[:name] }, "agent_core.llm.rate_limit"
  end

  def test_rails_transactional_test_harness_rolls_back_database_writes
    credential = create_provider_credential!
    @rollback_probe_credential_id = credential.id

    assert_predicate self.class, :use_transactional_tests
    assert_predicate ActiveRecord::Base.connection, :transaction_open?
    assert_predicate LLMProviderCredential, :exists?, credential.id
  end

  private

  def after_teardown
    rollback_probe_credential_id = @rollback_probe_credential_id
    super
    return if rollback_probe_credential_id.blank?

    assert_nil LLMProviderCredential.find_by(id: rollback_probe_credential_id)
  end

  def build_provider(adapter:)
    client = SimpleInference::Client.new(base_url: "http://example.com", api_key: "x", adapter: adapter)
    AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client)
  end

  def governance_options(credential:, owner_id:, instrumenter: AgentCore::Observability::NullInstrumenter.new)
    {
      provider_credential_id: credential.id,
      owner_type: "RunDraft",
      owner_id: owner_id,
      request_namespace: "turn-1",
      estimated_tokens: 32,
      instrumenter: instrumenter,
    }
  end

  def create_provider_credential!(attributes = {})
    provider_key = attributes[:provider_key] || "openai-#{SecureRandom.hex(4)}"
    LLMProviderCredential.create!(
      {
        provider_key: provider_key,
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 1,
        requests_per_minute: 60,
        tokens_per_minute: 120_000,
        burst_limit: 8,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
      }.merge(attributes),
    )
  end
end
