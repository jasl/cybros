require "test_helper"

class Conduits::CommandTargetResolverTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @resolver = Conduits::CommandTargetResolver.new
  end

  test "resolve by territory_id" do
    territory = Conduits::Territory.create!(
      account: @account, name: "mobile", kind: "mobile",
      capabilities: ["camera.snap"]
    )
    territory.activate!

    result = @resolver.resolve(
      account: @account,
      capability: "camera.snap",
      target: { territory_id: territory.id }
    )

    assert_equal territory, result.territory
    assert_nil result.entity
  end

  test "resolve by capability and location" do
    t1 = Conduits::Territory.create!(
      account: @account, name: "mobile-home", kind: "mobile",
      capabilities: ["camera.snap"], location: "home"
    )
    t1.activate!

    t2 = Conduits::Territory.create!(
      account: @account, name: "mobile-office", kind: "mobile",
      capabilities: ["camera.snap"], location: "office"
    )
    t2.activate!

    result = @resolver.resolve(
      account: @account,
      capability: "camera.snap",
      target: { location: "home" }
    )

    assert_equal t1, result.territory
  end

  test "resolve by tag" do
    t1 = Conduits::Territory.create!(
      account: @account, name: "phone", kind: "mobile",
      capabilities: ["location.get"], tags: ["james-phone"]
    )
    t1.activate!

    result = @resolver.resolve(
      account: @account,
      capability: "location.get",
      target: { tag: "james-phone" }
    )

    assert_equal t1, result.territory
  end

  test "resolve via bridge entity" do
    bridge = Conduits::Territory.create!(
      account: @account, name: "ha-bridge", kind: "bridge"
    )
    bridge.activate!

    entity = Conduits::BridgeEntity.create!(
      territory: bridge, account: @account,
      entity_ref: "light.living_room", entity_type: "light",
      capabilities: ["iot.light.control"],
      location: "home/living-room", available: true
    )

    result = @resolver.resolve(
      account: @account,
      capability: "iot.light.control",
      target: { location: "home" }
    )

    assert_equal bridge, result.territory
    assert_equal entity, result.entity
  end

  test "raises NoTargetAvailable when no match" do
    assert_raises Conduits::NoTargetAvailable do
      @resolver.resolve(
        account: @account,
        capability: "camera.snap",
        target: {}
      )
    end
  end

  test "prefers direct territory over bridge entity" do
    mobile = Conduits::Territory.create!(
      account: @account, name: "phone", kind: "mobile",
      capabilities: ["camera.snap"], location: "home"
    )
    mobile.activate!

    bridge = Conduits::Territory.create!(
      account: @account, name: "bridge", kind: "bridge"
    )
    bridge.activate!

    Conduits::BridgeEntity.create!(
      territory: bridge, account: @account,
      entity_ref: "camera.front", entity_type: "camera",
      capabilities: ["camera.snap"], location: "home", available: true
    )

    result = @resolver.resolve(
      account: @account,
      capability: "camera.snap",
      target: { location: "home" }
    )

    # Direct territory should be preferred
    assert_equal mobile, result.territory
    assert_nil result.entity
  end

  test "resolve entity by entity_ref on bridge" do
    bridge = Conduits::Territory.create!(
      account: @account, name: "bridge", kind: "bridge",
      capabilities: ["iot.light.control"]
    )
    bridge.activate!

    e1 = Conduits::BridgeEntity.create!(
      territory: bridge, account: @account,
      entity_ref: "light.a", entity_type: "light",
      capabilities: ["iot.light.control"], available: true
    )
    e2 = Conduits::BridgeEntity.create!(
      territory: bridge, account: @account,
      entity_ref: "light.b", entity_type: "light",
      capabilities: ["iot.light.control"], available: true
    )

    result = @resolver.resolve(
      account: @account,
      capability: "iot.light.control",
      target: { territory_id: bridge.id, entity_ref: "light.b" }
    )

    assert_equal bridge, result.territory
    assert_equal e2, result.entity
  end
end
