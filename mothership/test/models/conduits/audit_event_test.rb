require "test_helper"

class Conduits::AuditEventTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @user = User.create!(account: @account, name: "test-user")
    @territory = Conduits::Territory.create!(account: @account, name: "test-territory")
    @territory.activate!
    @facility = Conduits::Facility.create!(
      account: @account,
      owner: @user,
      territory: @territory,
      kind: "repo",
      retention_policy: "keep_last_5"
    )
    @directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )
  end

  test "creates audit event with all fields" do
    event = Conduits::AuditEvent.create!(
      account: @account,
      directive: @directive,
      actor: @user,
      event_type: "directive.created",
      severity: "info",
      payload: { "verdict" => "skip" },
      context: { "source" => "test" }
    )

    assert event.persisted?
    assert_equal @account.id, event.account_id
    assert_equal @directive.id, event.directive_id
    assert_equal @user.id, event.actor_id
    assert_equal "directive.created", event.event_type
    assert_equal "info", event.severity
    assert_equal({ "verdict" => "skip" }, event.payload)
  end

  test "requires event_type" do
    event = Conduits::AuditEvent.new(account: @account, severity: "info")
    assert_not event.valid?
    assert_includes event.errors[:event_type], "can't be blank"
  end

  test "validates severity inclusion" do
    event = Conduits::AuditEvent.new(
      account: @account, event_type: "test", severity: "invalid"
    )
    assert_not event.valid?
    assert event.errors[:severity].present?
  end

  test "allows nil directive" do
    event = Conduits::AuditEvent.create!(
      account: @account,
      event_type: "directive.policy_forbidden",
      severity: "critical"
    )
    assert event.persisted?
    assert_nil event.directive_id
  end

  test "by_type scope filters events" do
    Conduits::AuditEvent.create!(
      account: @account, event_type: "directive.created", severity: "info"
    )
    Conduits::AuditEvent.create!(
      account: @account, event_type: "directive.approved", severity: "info"
    )

    created_events = Conduits::AuditEvent.by_type("directive.created")
    assert_equal 1, created_events.count
  end

  test "critical scope filters critical events" do
    Conduits::AuditEvent.create!(
      account: @account, event_type: "directive.created", severity: "info"
    )
    Conduits::AuditEvent.create!(
      account: @account, event_type: "directive.policy_forbidden", severity: "critical"
    )

    critical = Conduits::AuditEvent.critical
    assert_equal 1, critical.count
    assert_equal "critical", critical.first.severity
  end

  test "recent scope returns ordered limited events" do
    5.times do |i|
      Conduits::AuditEvent.create!(
        account: @account, event_type: "directive.created", severity: "info"
      )
    end

    recent = Conduits::AuditEvent.recent
    assert recent.count <= 100
    # Should be ordered by created_at desc
    dates = recent.pluck(:created_at)
    assert_equal dates.sort.reverse, dates
  end
end
