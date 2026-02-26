require "test_helper"

class Conduits::DevicePolicyV1Test < ActiveSupport::TestCase
  test "matches_any? exact match" do
    assert Conduits::DevicePolicyV1.matches_any?("camera.snap", ["camera.snap"])
    refute Conduits::DevicePolicyV1.matches_any?("camera.snap", ["camera.record"])
  end

  test "matches_any? wildcard" do
    assert Conduits::DevicePolicyV1.matches_any?("camera.snap", ["camera.*"])
    assert Conduits::DevicePolicyV1.matches_any?("camera.record", ["camera.*"])
    refute Conduits::DevicePolicyV1.matches_any?("audio.record", ["camera.*"])
  end

  test "matches_any? global wildcard" do
    assert Conduits::DevicePolicyV1.matches_any?("anything.here", ["*"])
  end

  test "matches_any? empty patterns" do
    refute Conduits::DevicePolicyV1.matches_any?("camera.snap", [])
    refute Conduits::DevicePolicyV1.matches_any?("camera.snap", nil)
  end

  test "evaluate allowed" do
    policy = build_policy(device: { "allowed" => ["camera.*", "location.get"] })
    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [policy])
    assert_equal :allowed, result.verdict
  end

  test "evaluate denied takes precedence" do
    policy = build_policy(device: {
      "allowed" => ["camera.*"],
      "denied" => ["camera.snap"],
    })
    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [policy])
    assert_equal :denied, result.verdict
    assert_match /explicitly denied/, result.reason
  end

  test "evaluate not in allowed list" do
    policy = build_policy(device: { "allowed" => ["camera.*"] })
    result = Conduits::DevicePolicyV1.evaluate("sms.send", [policy])
    assert_equal :denied, result.verdict
    assert_match /not in allowed/, result.reason
  end

  test "evaluate needs_approval" do
    policy = build_policy(device: {
      "allowed" => ["camera.*"],
      "approval_required" => ["camera.record"],
    })
    result = Conduits::DevicePolicyV1.evaluate("camera.record", [policy])
    assert_equal :needs_approval, result.verdict
  end

  test "merge_policies intersection of allowed" do
    p1 = build_policy(device: { "allowed" => ["camera.*", "location.get"] }, priority: 0)
    p2 = build_policy(device: { "allowed" => ["camera.snap", "audio.*"] }, priority: 10)

    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [p1, p2])
    assert_equal :allowed, result.verdict

    # camera.record is allowed by camera.* but not by p2's exact list
    result2 = Conduits::DevicePolicyV1.evaluate("camera.record", [p1, p2])
    assert_equal :denied, result2.verdict
  end

  test "merge_policies union of denied" do
    p1 = build_policy(device: { "allowed" => ["*"], "denied" => ["sms.send"] }, priority: 0)
    p2 = build_policy(device: { "allowed" => ["*"], "denied" => ["camera.record"] }, priority: 10)

    result = Conduits::DevicePolicyV1.evaluate("sms.send", [p1, p2])
    assert_equal :denied, result.verdict

    result2 = Conduits::DevicePolicyV1.evaluate("camera.record", [p1, p2])
    assert_equal :denied, result2.verdict
  end

  test "merge_policies union of approval_required" do
    p1 = build_policy(device: { "allowed" => ["*"], "approval_required" => ["camera.record"] }, priority: 0)
    p2 = build_policy(device: { "allowed" => ["*"], "approval_required" => ["iot.lock.control"] }, priority: 10)

    result = Conduits::DevicePolicyV1.evaluate("camera.record", [p1, p2])
    assert_equal :needs_approval, result.verdict

    result2 = Conduits::DevicePolicyV1.evaluate("iot.lock.control", [p1, p2])
    assert_equal :needs_approval, result2.verdict
  end

  test "no allowed declaration defaults to deny-all" do
    policy = build_policy(device: {})
    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [policy])
    assert_equal :denied, result.verdict
  end

  # --- Tests with real Policy model records ---

  test "evaluate with real Policy records" do
    account = Account.create!(name: "device-policy-test")
    policy = Conduits::Policy.create!(
      account: account,
      name: "real-device-policy",
      priority: 0,
      device: { "allowed" => ["camera.*", "location.get"], "denied" => ["camera.record"] }
    )

    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [policy])
    assert_equal :allowed, result.verdict

    result2 = Conduits::DevicePolicyV1.evaluate("camera.record", [policy])
    assert_equal :denied, result2.verdict
  end

  test "merge real Policy records with intersection semantics" do
    account = Account.create!(name: "merge-policy-test")
    p1 = Conduits::Policy.create!(
      account: account, name: "global", priority: 0,
      device: { "allowed" => ["camera.*", "audio.*"] }
    )
    p2 = Conduits::Policy.create!(
      account: account, name: "restricted", priority: 10,
      device: { "allowed" => ["camera.snap"], "approval_required" => ["camera.snap"] }
    )

    result = Conduits::DevicePolicyV1.evaluate("camera.snap", [p1, p2])
    assert_equal :needs_approval, result.verdict

    # audio.* is not in p2's allowed list, so it gets denied after intersection
    result2 = Conduits::DevicePolicyV1.evaluate("audio.record", [p1, p2])
    assert_equal :denied, result2.verdict
  end

  private

  FakePolicy = Struct.new(:priority, :device, keyword_init: true)

  def build_policy(device: {}, priority: 0)
    FakePolicy.new(priority: priority, device: device)
  end
end
