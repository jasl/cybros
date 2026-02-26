require "test_helper"

class Conduits::ApprovalEvaluatorTest < ActiveSupport::TestCase
  test "empty rules returns skip" do
    result = evaluate(rules: {}, profile: "untrusted", caps: {})
    assert_equal :skip, result.verdict
    assert_empty result.reasons
  end

  test "default skip rule returns skip" do
    result = evaluate(rules: { "default" => "skip" }, profile: "untrusted", caps: {})
    assert_equal :skip, result.verdict
  end

  test "host_profile needs_approval triggers for host profile" do
    result = evaluate(
      rules: { "host_profile" => "needs_approval" },
      profile: "host",
      caps: {}
    )
    assert_equal :needs_approval, result.verdict
    assert_includes result.reasons.join, "host"
  end

  test "host_profile rule does not trigger for untrusted" do
    result = evaluate(
      rules: { "host_profile" => "needs_approval" },
      profile: "untrusted",
      caps: {}
    )
    assert_equal :skip, result.verdict
  end

  test "net_unrestricted forbidden triggers when net mode is unrestricted" do
    result = evaluate(
      rules: { "net_unrestricted" => "forbidden" },
      profile: "untrusted",
      caps: { "net" => { "mode" => "unrestricted" } }
    )
    assert_equal :forbidden, result.verdict
    assert_includes result.reasons.join, "net"
  end

  test "net_unrestricted does not trigger for allowlist mode" do
    result = evaluate(
      rules: { "net_unrestricted" => "forbidden" },
      profile: "untrusted",
      caps: { "net" => { "mode" => "allowlist" } }
    )
    assert_equal :skip, result.verdict
  end

  test "worst verdict wins: forbidden > needs_approval" do
    result = evaluate(
      rules: {
        "host_profile" => "needs_approval",
        "net_unrestricted" => "forbidden",
      },
      profile: "host",
      caps: { "net" => { "mode" => "unrestricted" } }
    )
    assert_equal :forbidden, result.verdict
    assert result.reasons.length >= 2
  end

  test "worst verdict wins: needs_approval > skip" do
    result = evaluate(
      rules: {
        "host_profile" => "needs_approval",
        "net_unrestricted" => "skip",
      },
      profile: "host",
      caps: { "net" => { "mode" => "unrestricted" } }
    )
    assert_equal :needs_approval, result.verdict
  end

  test "fs_outside_workspace triggers when write paths extend beyond workspace" do
    result = evaluate(
      rules: { "fs_outside_workspace" => "needs_approval" },
      profile: "trusted",
      caps: { "fs" => { "write" => ["/workspace", "/tmp"] } }
    )
    assert_equal :needs_approval, result.verdict
  end

  test "fs_outside_workspace does not trigger for workspace-only paths" do
    result = evaluate(
      rules: { "fs_outside_workspace" => "needs_approval" },
      profile: "trusted",
      caps: { "fs" => { "write" => ["workspace:**"] } }
    )
    assert_equal :skip, result.verdict
  end

  private

  def evaluate(rules:, profile:, caps:)
    Conduits::ApprovalEvaluator.new(
      effective_capabilities: caps,
      approval_rules: rules,
      sandbox_profile: profile
    ).evaluate
  end
end
