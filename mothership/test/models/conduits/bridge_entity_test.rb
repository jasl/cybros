require "test_helper"

class Conduits::BridgeEntityTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @bridge = Conduits::Territory.create!(
      account: @account, name: "ha-bridge", kind: "bridge", platform: "homeassistant"
    )
  end

  test "valid bridge entity" do
    entity = Conduits::BridgeEntity.new(
      territory: @bridge,
      account: @account,
      entity_ref: "light.living_room",
      entity_type: "light",
      capabilities: ["iot.light.control"]
    )
    assert entity.valid?
  end

  test "requires entity_ref" do
    entity = Conduits::BridgeEntity.new(
      territory: @bridge, account: @account, entity_type: "light"
    )
    refute entity.valid?
    assert entity.errors[:entity_ref].any?
  end

  test "requires entity_type" do
    entity = Conduits::BridgeEntity.new(
      territory: @bridge, account: @account, entity_ref: "light.x"
    )
    refute entity.valid?
    assert entity.errors[:entity_type].any?
  end

  test "entity_ref must be unique per territory" do
    Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.living_room", entity_type: "light"
    )
    dup = Conduits::BridgeEntity.new(
      territory: @bridge, account: @account,
      entity_ref: "light.living_room", entity_type: "light"
    )
    refute dup.valid?
    assert dup.errors[:entity_ref].any?
  end

  test "territory must be a bridge" do
    server = Conduits::Territory.create!(account: @account, name: "server", kind: "server")
    entity = Conduits::BridgeEntity.new(
      territory: server, account: @account,
      entity_ref: "light.x", entity_type: "light"
    )
    refute entity.valid?
    assert entity.errors[:territory].any?
  end

  test "with_capability scope" do
    e1 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.living", entity_type: "light",
      capabilities: ["iot.light.control", "iot.light.brightness"]
    )
    e2 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "sensor.temp", entity_type: "sensor",
      capabilities: ["sensor.temperature"]
    )

    results = Conduits::BridgeEntity.with_capability("iot.light.control")
    assert_includes results, e1
    refute_includes results, e2
  end

  test "available scope" do
    e1 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.a", entity_type: "light", available: true
    )
    e2 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.b", entity_type: "light", available: false
    )

    results = Conduits::BridgeEntity.available
    assert_includes results, e1
    refute_includes results, e2
  end

  test "at_location scope" do
    e1 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.living", entity_type: "light",
      location: "home/living-room"
    )
    e2 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.office", entity_type: "light",
      location: "office/floor-1"
    )

    results = Conduits::BridgeEntity.at_location("home")
    assert_includes results, e1
    refute_includes results, e2
  end
end
