require "test_helper"

class Conduits::AuditEventCleanupJobTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
  end

  test "deletes audit events older than TTL" do
    old_event = Conduits::AuditEvent.create!(
      account: @account,
      event_type: "directive.created",
      severity: "info"
    )
    old_event.update_columns(created_at: 91.days.ago)

    recent_event = Conduits::AuditEvent.create!(
      account: @account,
      event_type: "directive.created",
      severity: "info"
    )

    Conduits::AuditEventCleanupJob.new.perform(ttl_days: 90)

    assert_not Conduits::AuditEvent.exists?(old_event.id)
    assert Conduits::AuditEvent.exists?(recent_event.id)
  end

  test "respects batch_size and max_batches" do
    5.times do
      event = Conduits::AuditEvent.create!(
        account: @account,
        event_type: "directive.created",
        severity: "info"
      )
      event.update_columns(created_at: 91.days.ago)
    end

    # batch_size=2, max_batches=1 should only delete 2
    Conduits::AuditEventCleanupJob.new.perform(
      ttl_days: 90, batch_size: 2, max_batches: 1, sleep_seconds: 0
    )

    assert_equal 3, Conduits::AuditEvent.count
  end

  test "does nothing when ttl_days is zero" do
    event = Conduits::AuditEvent.create!(
      account: @account,
      event_type: "directive.created",
      severity: "info"
    )
    event.update_columns(created_at: 200.days.ago)

    Conduits::AuditEventCleanupJob.new.perform(ttl_days: 0)

    assert Conduits::AuditEvent.exists?(event.id)
  end
end
