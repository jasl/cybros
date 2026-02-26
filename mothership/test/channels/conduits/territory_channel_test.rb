require "test_helper"
require "action_cable/testing/rspec" if defined?(RSpec)

class Conduits::TerritoryChannelTest < ActionCable::Channel::TestCase
  tests Conduits::TerritoryChannel

  setup do
    @account = Account.create!(name: "channel-test")
    @territory = Conduits::Territory.create!(
      account: @account, name: "ws-territory", kind: "server"
    )
    @territory.activate!
  end

  test "subscribe sets websocket_connected_at and creates audit event" do
    stub_connection(current_territory: @territory)

    subscribe

    assert subscription.confirmed?
    @territory.reload
    assert @territory.websocket_connected_at.present?, "websocket_connected_at set"

    audit = Conduits::AuditEvent.find_by(event_type: "territory.websocket_connected")
    assert audit, "Audit event created for WebSocket connect"
    assert_equal @territory.id, audit.payload["territory_id"]
    assert_equal @territory.name, audit.payload["territory_name"]
  end

  test "unsubscribe clears websocket_connected_at and creates audit event" do
    @territory.update!(websocket_connected_at: Time.current)
    stub_connection(current_territory: @territory)

    subscribe
    unsubscribe

    @territory.reload
    assert_nil @territory.websocket_connected_at, "websocket_connected_at cleared"

    audit = Conduits::AuditEvent.find_by(event_type: "territory.websocket_disconnected")
    assert audit, "Audit event created for WebSocket disconnect"
    assert_equal @territory.id, audit.payload["territory_id"]
  end

  test "subscribe rejected without territory" do
    stub_connection(current_territory: nil)

    subscribe

    assert subscription.rejected?
  end

  test "broadcast directive_available is received by subscribers" do
    stub_connection(current_territory: @territory)
    subscribe

    payload = { type: "directive_available", directive_id: "test-123", sandbox_profile: "untrusted" }

    assert_broadcast_on(Conduits::TerritoryChannel.broadcasting_for(@territory), payload) do
      Conduits::TerritoryChannel.broadcast_to(@territory, payload)
    end
  end
end
