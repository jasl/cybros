require "test_helper"

class Conduits::CommandPolicyGateTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "gate-test")
    @user = User.create!(account: @account, name: "tester")
  end

  test "allows when no policies exist (backwards compatibility)" do
    result = gate("camera.snap").call
    assert_equal :allowed, result.verdict
    assert_nil result.reason
  end

  test "allows when policies have no device section" do
    Conduits::Policy.create!(
      account: @account, name: "no-device", priority: 0,
      fs: { "read" => ["workspace:**"] }, device: {}
    )
    result = gate("camera.snap").call
    assert_equal :allowed, result.verdict
  end

  test "allows explicitly allowed capability" do
    Conduits::Policy.create!(
      account: @account, name: "allow-camera", priority: 0,
      device: { "allowed" => ["camera.*"] }
    )
    result = gate("camera.snap").call
    assert_equal :allowed, result.verdict
  end

  test "denies explicitly denied capability" do
    Conduits::Policy.create!(
      account: @account, name: "deny-sms", priority: 0,
      device: { "allowed" => ["*"], "denied" => ["sms.send"] }
    )
    result = gate("sms.send").call
    assert_equal :denied, result.verdict
    assert_match(/explicitly denied/, result.reason)
  end

  test "denies capability not in allowed list" do
    Conduits::Policy.create!(
      account: @account, name: "camera-only", priority: 0,
      device: { "allowed" => ["camera.*"] }
    )
    result = gate("sms.send").call
    assert_equal :denied, result.verdict
    assert_match(/not in allowed/, result.reason)
  end

  test "requires approval for approval_required capability" do
    Conduits::Policy.create!(
      account: @account, name: "lock-approval", priority: 0,
      device: { "allowed" => ["*"], "approval_required" => ["iot.lock.control"] }
    )
    result = gate("iot.lock.control").call
    assert_equal :needs_approval, result.verdict
  end

  test "policy snapshot includes evaluation metadata" do
    Conduits::Policy.create!(
      account: @account, name: "test-policy", priority: 0,
      device: { "allowed" => ["camera.*"] }
    )
    result = gate("camera.snap").call
    assert result.policy_snapshot["evaluated_at"].present?
    assert_equal "camera.snap", result.policy_snapshot["capability"]
    assert_equal "allowed", result.policy_snapshot["verdict"]
  end

  private

  def gate(capability)
    Conduits::CommandPolicyGate.new(
      account: @account, capability: capability, user: @user
    )
  end
end
