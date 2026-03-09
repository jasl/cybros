require "test_helper"

class RuntimeGovernance::RuntimeWaitsTest < ActiveSupport::TestCase
  test "parks waits idempotently for the same owner and governed subject" do
    parked =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RunDraft",
        owner_id: "draft-1",
        reason_type: "provider_limit",
        subject_type: "llm_provider_credential",
        subject_id: SecureRandom.uuid,
        retry_at: 1.minute.from_now,
        details: { "provider_request_id" => "provider-req-1" },
      )

    duplicate =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RunDraft",
        owner_id: "draft-1",
        reason_type: "provider_limit",
        subject_type: parked.subject_type,
        subject_id: parked.subject_id,
        retry_at: 2.minutes.from_now,
        details: { "provider_request_id" => "provider-req-1" },
      )

    assert_equal parked.id, duplicate.id
    assert_equal 1, RuntimeWait.count
  end

  test "returns the oldest ready wait first within one reason and subject" do
    subject_id = SecureRandom.uuid
    now = Time.current.change(usec: 0)
    newer =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: "run-2",
        reason_type: "execution_quota",
        subject_type: "execution_location",
        subject_id: subject_id,
        retry_at: now,
        details: {},
        now: now + 5.seconds,
      )
    older =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: "run-1",
        reason_type: "execution_quota",
        subject_type: "execution_location",
        subject_id: subject_id,
        retry_at: now,
        details: {},
        now: now,
      )
    RuntimeGovernance::RuntimeWaits.park!(
      owner_type: "ConversationRun",
      owner_id: "run-3",
      reason_type: "execution_quota",
      subject_type: "execution_location",
      subject_id: subject_id,
      retry_at: now + 5.minutes,
      details: {},
      now: now + 10.seconds,
    )

    ready =
      RuntimeGovernance::RuntimeWaits.next_ready(
        reason_type: "execution_quota",
        subject_type: "execution_location",
        subject_id: subject_id,
        now: now + 30.seconds,
      )

    assert_equal older.id, ready.id
    refute_equal newer.id, ready.id
  end

  test "resumes parked waits and accepts deployment_backoff as a durable wait reason" do
    wait =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "AgentDeployment",
        owner_id: SecureRandom.uuid,
        reason_type: "deployment_backoff",
        subject_type: "agent_deployment",
        subject_id: SecureRandom.uuid,
        retry_at: 1.minute.from_now,
        details: { "attempt" => 2 },
      )

    resumed = RuntimeGovernance::RuntimeWaits.resume!(wait: wait)

    assert_equal "resumed", resumed.status
  end
end
