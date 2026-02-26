require "test_helper"

class Conduits::CommandTimeoutJobTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "timeout-test")
    @territory = Conduits::Territory.create!(
      account: @account, name: "mobile", kind: "mobile",
      capabilities: ["camera.snap", "location.get"]
    )
    @territory.activate!
  end

  test "reaps expired queued commands" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 5
    )
    cmd.update_column(:created_at, 10.seconds.ago)

    Conduits::CommandTimeoutJob.perform_now

    cmd.reload
    assert_equal "timed_out", cmd.state
    assert cmd.completed_at.present?
  end

  test "reaps expired dispatched commands" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 5
    )
    cmd.dispatch!
    cmd.update_column(:created_at, 10.seconds.ago)

    Conduits::CommandTimeoutJob.perform_now

    cmd.reload
    assert_equal "timed_out", cmd.state
  end

  test "does not reap non-expired commands" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 300
    )

    Conduits::CommandTimeoutJob.perform_now

    cmd.reload
    assert_equal "queued", cmd.state
  end

  test "skips already-terminal commands gracefully" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 5
    )
    cmd.dispatch!
    cmd.complete!
    cmd.update_column(:created_at, 10.seconds.ago)

    # Should not raise even if the expired scope somehow returns a terminal command
    assert_nothing_raised { Conduits::CommandTimeoutJob.perform_now }
    cmd.reload
    assert_equal "completed", cmd.state
  end

  test "creates audit event for timed out commands" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "location.get", timeout_seconds: 1
    )
    cmd.update_column(:created_at, 5.seconds.ago)

    Conduits::CommandTimeoutJob.perform_now

    audit = Conduits::AuditEvent.where(
      account: @account, event_type: "command.timed_out"
    ).find { |e| e.payload["command_id"] == cmd.id }
    assert audit, "Should create audit event for timed out command"
    assert_equal "location.get", audit.payload["capability"]
  end
end
