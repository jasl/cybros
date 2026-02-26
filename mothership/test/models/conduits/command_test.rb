require "test_helper"

class Conduits::CommandTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @territory = Conduits::Territory.create!(
      account: @account, name: "mobile-1", kind: "mobile",
      capabilities: ["camera.snap", "location.get"]
    )
  end

  test "valid command" do
    cmd = Conduits::Command.new(
      account: @account,
      territory: @territory,
      capability: "camera.snap",
      params: { facing: "back", quality: 80 }
    )
    assert cmd.valid?, "Errors: #{cmd.errors.full_messages}"
  end

  test "capability must be present" do
    cmd = Conduits::Command.new(account: @account, territory: @territory)
    refute cmd.valid?
    assert cmd.errors[:capability].any?
  end

  test "capability must be supported by territory" do
    cmd = Conduits::Command.new(
      account: @account, territory: @territory,
      capability: "sms.send"
    )
    refute cmd.valid?
    assert cmd.errors[:capability].any?
  end

  test "capability supported by bridge entity" do
    bridge = Conduits::Territory.create!(
      account: @account, name: "ha-bridge", kind: "bridge",
      capabilities: []
    )
    entity = Conduits::BridgeEntity.create!(
      territory: bridge, account: @account,
      entity_ref: "light.living", entity_type: "light",
      capabilities: ["iot.light.control"]
    )

    cmd = Conduits::Command.new(
      account: @account, territory: bridge,
      bridge_entity: entity, capability: "iot.light.control"
    )
    assert cmd.valid?
  end

  test "bridge_entity must belong to territory" do
    bridge1 = Conduits::Territory.create!(
      account: @account, name: "bridge1", kind: "bridge"
    )
    bridge2 = Conduits::Territory.create!(
      account: @account, name: "bridge2", kind: "bridge"
    )
    entity = Conduits::BridgeEntity.create!(
      territory: bridge1, account: @account,
      entity_ref: "light.x", entity_type: "light",
      capabilities: ["iot.light.control"]
    )

    cmd = Conduits::Command.new(
      account: @account, territory: bridge2,
      bridge_entity: entity, capability: "iot.light.control"
    )
    refute cmd.valid?
    assert cmd.errors[:bridge_entity].any?
  end

  test "timeout_seconds validation" do
    cmd = Conduits::Command.new(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 0
    )
    refute cmd.valid?
    assert cmd.errors[:timeout_seconds].any?

    cmd2 = Conduits::Command.new(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 301
    )
    refute cmd2.valid?
    assert cmd2.errors[:timeout_seconds].any?
  end

  test "AASM state transitions" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap"
    )
    assert_equal "queued", cmd.state

    cmd.dispatch!
    assert_equal "dispatched", cmd.state
    assert cmd.dispatched_at.present?

    cmd.complete!
    assert_equal "completed", cmd.state
    assert cmd.completed_at.present?
    assert cmd.terminal?
  end

  test "AASM fail transition" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap"
    )
    cmd.dispatch!
    cmd.fail!
    assert_equal "failed", cmd.state
    assert cmd.terminal?
  end

  test "AASM time_out transition" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap"
    )
    cmd.time_out!
    assert_equal "timed_out", cmd.state
    assert cmd.terminal?
  end

  test "AASM cancel transition" do
    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap"
    )
    cmd.cancel!
    assert_equal "canceled", cmd.state
    assert cmd.terminal?
  end

  test "expired scope" do
    old_cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 1
    )
    old_cmd.update_column(:created_at, 10.seconds.ago)

    fresh_cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "location.get", timeout_seconds: 300
    )

    expired = Conduits::Command.expired
    assert_includes expired, old_cmd
    refute_includes expired, fresh_cmd
  end

  test "pending scope" do
    c1 = Conduits::Command.create!(account: @account, territory: @territory, capability: "camera.snap")
    c2 = Conduits::Command.create!(account: @account, territory: @territory, capability: "location.get")
    c2.dispatch!
    c3 = Conduits::Command.create!(account: @account, territory: @territory, capability: "camera.snap")
    c3.dispatch!
    c3.complete!

    pending = Conduits::Command.pending
    assert_includes pending, c1
    assert_includes pending, c2
    refute_includes pending, c3
  end
end
