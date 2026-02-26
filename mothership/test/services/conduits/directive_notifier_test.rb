require "test_helper"

class Conduits::DirectiveNotifierTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "notifier-test")
    @user = User.create!(account: @account, name: "notifier-user")
    @facility = Conduits::Facility.create!(
      account: @account,
      owner: @user,
      territory: Conduits::Territory.create!(account: @account, name: "facility-territory"),
      kind: "repo",
      retention_policy: "keep_last_5",
      repo_url: "https://github.com/example/test"
    )
    @notifier = Conduits::DirectiveNotifier.new
  end

  test "broadcasts to online, directive-capable, WS-connected territory" do
    territory = create_ws_territory("ws-server", kind: "server")
    directive = create_queued_directive

    # broadcast_to is no-op in test adapter but should not raise
    @notifier.notify(directive)

    audit = Conduits::AuditEvent.find_by(event_type: "directive.wake_up_broadcast")
    assert audit, "Audit event created for wake-up broadcast"
    assert_equal 1, audit.payload["territory_count"]
    assert_equal "websocket", audit.payload["via"]
  end

  test "broadcasts to desktop territories (directive-capable)" do
    create_ws_territory("ws-desktop", kind: "desktop")
    directive = create_queued_directive

    @notifier.notify(directive)

    audit = Conduits::AuditEvent.find_by(event_type: "directive.wake_up_broadcast")
    assert audit
    assert_equal 1, audit.payload["territory_count"]
  end

  test "does not broadcast when no WS-connected territories exist" do
    # Territory exists but not WS-connected
    Conduits::Territory.create!(
      account: @account, name: "offline-server", kind: "server"
    ).activate!

    directive = create_queued_directive
    @notifier.notify(directive)

    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast"),
           "No audit event when no WS territories"
  end

  test "does not broadcast to offline territories" do
    territory = Conduits::Territory.create!(
      account: @account, name: "offline-ws", kind: "server",
      websocket_connected_at: Time.current
    )
    # Territory is still pending (not online), so not directive_capable
    directive = create_queued_directive
    @notifier.notify(directive)

    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast")
  end

  test "does not broadcast to mobile or bridge territories" do
    create_ws_territory("ws-mobile", kind: "mobile")
    create_ws_territory("ws-bridge", kind: "bridge")

    directive = create_queued_directive
    @notifier.notify(directive)

    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast"),
           "Mobile and bridge territories are not directive-capable"
  end

  test "does not broadcast to territories in other accounts" do
    other_account = Account.create!(name: "other-account")
    other_territory = Conduits::Territory.create!(
      account: other_account, name: "other-server", kind: "server",
      websocket_connected_at: Time.current
    )
    other_territory.activate!

    directive = create_queued_directive
    @notifier.notify(directive)

    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast"),
           "Should not broadcast to other account's territories"
  end

  test "broadcasts to multiple eligible territories" do
    create_ws_territory("ws-server-1", kind: "server")
    create_ws_territory("ws-server-2", kind: "server")
    create_ws_territory("ws-desktop-1", kind: "desktop")

    directive = create_queued_directive
    @notifier.notify(directive)

    audit = Conduits::AuditEvent.find_by(event_type: "directive.wake_up_broadcast")
    assert audit
    assert_equal 3, audit.payload["territory_count"]
  end

  test "skips non-queued directives" do
    create_ws_territory("ws-server", kind: "server")
    directive = create_queued_directive
    directive.update_column(:state, "awaiting_approval")

    @notifier.notify(directive)

    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast"),
           "Should not broadcast for non-queued directives"
  end

  test "gracefully handles broadcast failure" do
    create_ws_territory("ws-server", kind: "server")
    directive = create_queued_directive

    # Simulate broadcast failure by temporarily redefining broadcast_to
    original = Conduits::TerritoryChannel.method(:broadcast_to)
    Conduits::TerritoryChannel.define_singleton_method(:broadcast_to) do |*_args|
      raise "Redis down"
    end

    # Should not raise — fire-and-forget
    @notifier.notify(directive)

    # No audit event since the rescue catches before audit
    refute Conduits::AuditEvent.exists?(event_type: "directive.wake_up_broadcast")
  ensure
    Conduits::TerritoryChannel.define_singleton_method(:broadcast_to, original)
  end

  private

  def create_ws_territory(name, kind:)
    territory = Conduits::Territory.create!(
      account: @account, name: name, kind: kind,
      websocket_connected_at: Time.current
    )
    territory.activate!
    territory
  end

  def create_queued_directive
    Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60,
      requested_by_user: @user
    )
  end
end
