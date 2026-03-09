require "test_helper"

class RuntimeGovernance::ExecutionCapacityLeasesTest < ActiveSupport::TestCase
  test "acquires idempotently and releases execution leases by durable request id" do
    capacity = create_capacity_snapshot!(max_concurrent_tasks: 2, max_queued_tasks: 4)

    acquired =
      RuntimeGovernance::ExecutionCapacityLeases.acquire!(
        capacity: capacity,
        execution_request_id: "exec-1",
        holder_type: "ConversationRun",
        holder_id: SecureRandom.uuid,
      )

    duplicate =
      RuntimeGovernance::ExecutionCapacityLeases.acquire!(
        capacity: capacity,
        execution_request_id: "exec-1",
        holder_type: "ConversationRun",
        holder_id: SecureRandom.uuid,
      )

    lease = acquired.fetch(:lease)
    assert_equal "acquired", acquired.fetch(:decision)
    assert_equal lease.id, duplicate.fetch(:lease).id
    assert_equal(
      1,
      ExecutionCapacityLease.where(
        subject_type: capacity.fetch("scope_type"),
        subject_id: capacity.fetch("scope_id"),
        execution_request_id: "exec-1",
      ).count,
    )

    released =
      RuntimeGovernance::ExecutionCapacityLeases.release!(
        subject_type: capacity.fetch("scope_type"),
        subject_id: capacity.fetch("scope_id"),
        execution_request_id: "exec-1",
      )

    assert_equal "released", released.status
  end

  test "parks work when execution concurrency is exhausted" do
    capacity = create_capacity_snapshot!(max_concurrent_tasks: 1, max_queued_tasks: 2)

    RuntimeGovernance::ExecutionCapacityLeases.acquire!(
      capacity: capacity,
      execution_request_id: "exec-1",
      holder_type: "ConversationRun",
      holder_id: "run-1",
    )

    blocked =
      RuntimeGovernance::ExecutionCapacityLeases.acquire!(
        capacity: capacity,
        execution_request_id: "exec-2",
        holder_type: "ConversationRun",
        holder_id: "run-2",
      )

    assert_equal "parked", blocked.fetch(:decision)
    wait = blocked.fetch(:runtime_wait)
    assert_equal "execution_capacity", wait.reason_type
    assert_equal capacity.fetch("scope_type"), wait.subject_type
    assert_equal capacity.fetch("scope_id"), wait.subject_id
  end

  test "denies work when execution backlog is already at the queued limit" do
    capacity = create_capacity_snapshot!(max_concurrent_tasks: 1, max_queued_tasks: 1)

    RuntimeGovernance::ExecutionCapacityLeases.acquire!(
      capacity: capacity,
      execution_request_id: "exec-1",
      holder_type: "ConversationRun",
      holder_id: "run-1",
    )
    RuntimeGovernance::ExecutionCapacityLeases.acquire!(
      capacity: capacity,
      execution_request_id: "exec-2",
      holder_type: "ConversationRun",
      holder_id: "run-2",
    )

    denied =
      RuntimeGovernance::ExecutionCapacityLeases.acquire!(
        capacity: capacity,
        execution_request_id: "exec-3",
        holder_type: "ConversationRun",
        holder_id: "run-3",
      )

    assert_equal "denied", denied.fetch(:decision)
    assert_nil denied[:runtime_wait]
  end

  test "reconciles expired execution leases so new work can acquire" do
    capacity = create_capacity_snapshot!(max_concurrent_tasks: 1, max_queued_tasks: 2)
    stale =
      ExecutionCapacityLease.create!(
        subject_type: capacity.fetch("scope_type"),
        subject_id: capacity.fetch("scope_id"),
        execution_request_id: "exec-stale",
        holder_type: "ConversationRun",
        holder_id: SecureRandom.uuid,
        slots: 1,
        lease_expires_at: 1.minute.ago,
        heartbeat_at: 2.minutes.ago,
        status: "active",
        recovery_metadata: {},
      )

    count =
      RuntimeGovernance::ExecutionCapacityLeases.reconcile_expired!(
        subject_type: capacity.fetch("scope_type"),
        subject_id: capacity.fetch("scope_id"),
        now: Time.current,
      )

    assert_equal 1, count
    assert_equal "expired", stale.reload.status

    acquired =
      RuntimeGovernance::ExecutionCapacityLeases.acquire!(
        capacity: capacity,
        execution_request_id: "exec-2",
        holder_type: "ConversationRun",
        holder_id: "run-2",
      )

    assert_equal "acquired", acquired.fetch(:decision)
  end

  private

  def create_capacity_snapshot!(max_concurrent_tasks:, max_queued_tasks:)
    location =
      ExecutionLocation.create!(
        name: "Fixture host #{SecureRandom.hex(4)}",
        kind: "host",
        platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: ["fixture"],
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
        default_timeout_s: 900,
      )
    workspace =
      Workspace.create!(
        execution_location: location,
        name: "Fixture workspace #{SecureRandom.hex(4)}",
        root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
        capability_tags: ["git"],
        tags: ["fixture"],
      )
    target =
      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      )

    RuntimeGovernance::ExecutionCapacityResolver.resolve!(execution_target: target)
  end
end
