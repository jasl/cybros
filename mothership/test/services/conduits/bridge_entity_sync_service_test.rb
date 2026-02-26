require "test_helper"

class Conduits::BridgeEntitySyncServiceTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @bridge = Conduits::Territory.create!(
      account: @account, name: "ha-bridge", kind: "bridge", platform: "homeassistant"
    )
    @service = Conduits::BridgeEntitySyncService.new
  end

  test "creates new entities from heartbeat" do
    reported = [
      {
        "entity_ref" => "light.living_room",
        "entity_type" => "light",
        "display_name" => "Living Room Light",
        "capabilities" => ["iot.light.control"],
        "location" => "home/living-room",
        "state" => { "on" => true },
        "available" => true,
      },
    ]

    assert_difference "Conduits::BridgeEntity.count", 1 do
      @service.sync(territory: @bridge, reported_entities: reported)
    end

    entity = @bridge.bridge_entities.first
    assert_equal "light.living_room", entity.entity_ref
    assert_equal "light", entity.entity_type
    assert_equal "Living Room Light", entity.display_name
    assert_equal ["iot.light.control"], entity.capabilities
    assert entity.available
  end

  test "updates existing entities" do
    entity = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.living_room", entity_type: "light",
      display_name: "Old Name", capabilities: ["iot.light.control"],
      state: { "on" => false }
    )

    reported = [
      {
        "entity_ref" => "light.living_room",
        "entity_type" => "light",
        "display_name" => "New Name",
        "capabilities" => ["iot.light.control", "iot.light.brightness"],
        "state" => { "on" => true, "brightness" => 80 },
        "available" => true,
      },
    ]

    assert_no_difference "Conduits::BridgeEntity.count" do
      @service.sync(territory: @bridge, reported_entities: reported)
    end

    entity.reload
    assert_equal "New Name", entity.display_name
    assert_equal ["iot.light.control", "iot.light.brightness"], entity.capabilities
    assert_equal({ "on" => true, "brightness" => 80 }, entity.state)
  end

  test "marks missing entities as unavailable" do
    entity1 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.a", entity_type: "light", available: true
    )
    entity2 = Conduits::BridgeEntity.create!(
      territory: @bridge, account: @account,
      entity_ref: "light.b", entity_type: "light", available: true
    )

    reported = [
      { "entity_ref" => "light.a", "entity_type" => "light", "available" => true },
    ]

    @service.sync(territory: @bridge, reported_entities: reported)

    entity1.reload
    entity2.reload
    assert entity1.available
    refute entity2.available
  end

  test "skips non-bridge territories" do
    server = Conduits::Territory.create!(
      account: @account, name: "server", kind: "server"
    )

    assert_no_difference "Conduits::BridgeEntity.count" do
      @service.sync(territory: server, reported_entities: [
        { "entity_ref" => "light.x", "entity_type" => "light" },
      ])
    end
  end

  test "skips blank reported entities" do
    assert_no_difference "Conduits::BridgeEntity.count" do
      @service.sync(territory: @bridge, reported_entities: nil)
    end
  end
end
