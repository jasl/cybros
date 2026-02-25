require "test_helper"

class Conduits::AuditServiceTest < ActiveSupport::TestCase
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

  test "record creates an audit event" do
    service = Conduits::AuditService.new(
      account: @account,
      directive: @directive,
      actor: @user
    )

    event = service.record("directive.created", payload: { "verdict" => "skip" })

    assert event.persisted?
    assert_equal "directive.created", event.event_type
    assert_equal "info", event.severity
    assert_equal @directive.id, event.directive_id
    assert_equal @user.id, event.actor_id
    assert_equal({ "verdict" => "skip" }, event.payload)
  end

  test "record with severity" do
    service = Conduits::AuditService.new(account: @account)

    event = service.record(
      "directive.policy_forbidden",
      severity: "critical",
      payload: { "reasons" => ["host forbidden"] }
    )

    assert_equal "critical", event.severity
  end

  test "record without directive" do
    service = Conduits::AuditService.new(account: @account, actor: @user)

    event = service.record("directive.policy_forbidden", severity: "critical")

    assert event.persisted?
    assert_nil event.directive_id
    assert_equal @user.id, event.actor_id
  end

  test "record_directive_event fills directive payload" do
    service = Conduits::AuditService.new(
      account: @account,
      directive: @directive,
      actor: @user
    )

    event = service.record_directive_event(
      "directive.state_changed",
      extra: { "from" => "queued", "to" => "leased" }
    )

    assert event.persisted?
    assert_equal @directive.id, event.payload["directive_id"]
    assert_equal @directive.facility_id, event.payload["facility_id"]
    assert_equal "untrusted", event.payload["sandbox_profile"]
    assert_equal "queued", event.payload["from"]
    assert_equal "leased", event.payload["to"]
  end

  test "record with context" do
    service = Conduits::AuditService.new(
      account: @account,
      directive: @directive,
      context: { "request_id" => "abc-123" }
    )

    event = service.record("directive.created")

    assert_equal({ "request_id" => "abc-123" }, event.context)
  end

  test "record silently fails on validation error" do
    service = Conduits::AuditService.new(account: @account)

    # severity is invalid — should not raise
    result = service.record("directive.created", severity: "invalid")

    assert_nil result
  end
end
