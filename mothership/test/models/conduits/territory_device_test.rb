require "test_helper"

class Conduits::TerritoryDeviceTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
  end

  test "kind defaults to server" do
    t = Conduits::Territory.create!(account: @account, name: "default-kind")
    assert_equal "server", t.kind
  end

  test "kind validates inclusion" do
    t = Conduits::Territory.new(account: @account, name: "bad-kind", kind: "spaceship")
    refute t.valid?
    assert t.errors[:kind].any?
  end

  test "all valid kinds are accepted" do
    Conduits::Territory::KINDS.each do |kind|
      t = Conduits::Territory.new(account: @account, name: "test-#{kind}", kind: kind)
      assert t.valid?, "Kind '#{kind}' should be valid, errors: #{t.errors.full_messages}"
    end
  end

  test "with_capability scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "t1", capabilities: ["camera.snap", "location.get"])
    t2 = Conduits::Territory.create!(account: @account, name: "t2", capabilities: ["sandbox.exec"])
    t1.activate!
    t2.activate!

    results = Conduits::Territory.with_capability("camera.snap")
    assert_includes results, t1
    refute_includes results, t2
  end

  test "with_capability_matching wildcard scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "t1", capabilities: ["camera.snap", "camera.record"])
    t1.activate!

    results = Conduits::Territory.with_capability_matching("camera.*")
    assert_includes results, t1

    results2 = Conduits::Territory.with_capability_matching("audio.*")
    refute_includes results2, t1
  end

  test "at_location scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "t1", location: "home/living-room")
    t2 = Conduits::Territory.create!(account: @account, name: "t2", location: "office/floor-3")

    results = Conduits::Territory.at_location("home")
    assert_includes results, t1
    refute_includes results, t2
  end

  test "with_tag scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "t1", tags: ["homelab", "always-on"])
    t2 = Conduits::Territory.create!(account: @account, name: "t2", tags: ["production"])

    results = Conduits::Territory.with_tag("homelab")
    assert_includes results, t1
    refute_includes results, t2
  end

  test "websocket_connected?" do
    t = Conduits::Territory.create!(account: @account, name: "t1")
    refute t.websocket_connected?

    t.update!(websocket_connected_at: Time.current)
    assert t.websocket_connected?
  end

  test "websocket_connected scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "t1", websocket_connected_at: Time.current)
    t2 = Conduits::Territory.create!(account: @account, name: "t2")

    results = Conduits::Territory.websocket_connected
    assert_includes results, t1
    refute_includes results, t2
  end

  test "command_capable scope" do
    t1 = Conduits::Territory.create!(account: @account, name: "online-caps", capabilities: ["camera.snap"])
    t1.activate!
    t2 = Conduits::Territory.create!(account: @account, name: "online-nocaps")
    t2.activate!
    t3 = Conduits::Territory.create!(account: @account, name: "offline-caps", capabilities: ["camera.snap"])

    results = Conduits::Territory.command_capable
    assert_includes results, t1
    refute_includes results, t2
    refute_includes results, t3
  end

  test "directive_capable scope" do
    server = Conduits::Territory.create!(account: @account, name: "server", kind: "server")
    server.activate!
    mobile = Conduits::Territory.create!(account: @account, name: "mobile", kind: "mobile")
    mobile.activate!

    results = Conduits::Territory.directive_capable
    assert_includes results, server
    refute_includes results, mobile
  end

  test "record_heartbeat with capabilities" do
    t = Conduits::Territory.create!(account: @account, name: "t1")
    t.activate!

    t.record_heartbeat!(capabilities: ["camera.snap", "location.get"])
    t.reload
    assert_equal ["camera.snap", "location.get"], t.capabilities
  end

  test "supports_directives? returns true for server and desktop" do
    assert Conduits::Territory.new(kind: "server").supports_directives?
    assert Conduits::Territory.new(kind: "desktop").supports_directives?
    refute Conduits::Territory.new(kind: "mobile").supports_directives?
    refute Conduits::Territory.new(kind: "bridge").supports_directives?
  end
end
