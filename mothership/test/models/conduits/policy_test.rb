require "test_helper"

class Conduits::PolicyTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "test-account")
    @user = User.create!(account: @account, name: "test-user")
    @territory = Conduits::Territory.create!(account: @account, name: "test-territory")
    @territory.activate!
    @facility = Conduits::Facility.create!(
      account: @account,
      owner: @user,
      territory: @territory,
      kind: "repo",
      retention_policy: "keep_last_5"
    )
    @directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )
  end

  # effective_for — no policies

  test "effective_for returns defaults when no policies exist" do
    result = Conduits::Policy.effective_for(@directive)
    assert_kind_of Hash, result
    assert_equal [], result[:policy_ids]
    assert_kind_of Hash, result[:fs]
    assert_kind_of Hash, result[:net]
    assert_kind_of Hash, result[:approval]
  end

  # effective_for — single global policy

  test "effective_for applies single global policy" do
    policy = create_policy(
      name: "global-restrictive",
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"], "write" => [] },
      net: { "mode" => "none" },
      approval: { "host_profile" => "needs_approval" }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_includes result[:policy_ids], policy.id
    assert_equal({ "read" => ["workspace:**"], "write" => [] }, result[:fs])
    assert_equal({ "mode" => "none" }, result[:net])
    assert_equal({ "host_profile" => "needs_approval" }, result[:approval])
  end

  # effective_for — account-scoped policy

  test "effective_for applies account-scoped policy" do
    policy = create_policy(
      name: "account-policy",
      scope_type: "Account", scope_id: @account.id,
      fs: { "read" => ["workspace:**"], "write" => ["workspace:**"] },
      net: { "mode" => "allowlist", "allow" => ["github.com:443"] }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_includes result[:policy_ids], policy.id
    assert_equal "allowlist", result[:net]["mode"]
  end

  # effective_for — multi-scope merge (fs intersection)

  test "effective_for merges global + account with fs intersection" do
    create_policy(
      name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    )
    create_policy(
      name: "account-restrict", priority: 10,
      scope_type: "Account", scope_id: @account.id,
      fs: { "read" => ["workspace:**"], "write" => [] }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_equal 2, result[:policy_ids].length
    # Write intersection: ["workspace:**"] ∩ [] = []
    assert_empty result[:fs]["write"]
    # Read intersection: ["workspace:**"] ∩ ["workspace:**"] = ["workspace:**"]
    assert_includes result[:fs]["read"], "workspace:**"
  end

  # effective_for — net intersection

  test "effective_for merges net mode with restrictive ceiling" do
    create_policy(
      name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      net: { "mode" => "unrestricted" }
    )
    create_policy(
      name: "account", priority: 10,
      scope_type: "Account", scope_id: @account.id,
      net: { "mode" => "allowlist", "allow" => ["github.com:443"] }
    )

    result = Conduits::Policy.effective_for(@directive)
    # allowlist < unrestricted, so allowlist wins (restrictive ceiling)
    assert_equal "allowlist", result[:net]["mode"]
    assert_includes result[:net]["allow"], "github.com:443"
  end

  # effective_for — secrets priority replace

  test "effective_for uses priority replace for secrets" do
    create_policy(
      name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      secrets: { "allowed_refs" => ["SECRET_A", "SECRET_B"] }
    )
    create_policy(
      name: "facility", priority: 20,
      scope_type: "Conduits::Facility", scope_id: @facility.id,
      secrets: { "allowed_refs" => ["SECRET_C"] }
    )

    result = Conduits::Policy.effective_for(@directive)
    # Higher priority replaces entirely
    assert_equal({ "allowed_refs" => ["SECRET_C"] }, result[:secrets])
  end

  # effective_for — approval most-restrictive-wins

  test "effective_for uses most restrictive approval" do
    create_policy(
      name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      approval: { "host_profile" => "skip", "net_unrestricted" => "needs_approval" }
    )
    create_policy(
      name: "account", priority: 10,
      scope_type: "Account", scope_id: @account.id,
      approval: { "host_profile" => "needs_approval", "net_unrestricted" => "forbidden" }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_equal "needs_approval", result[:approval]["host_profile"]
    assert_equal "forbidden", result[:approval]["net_unrestricted"]
  end

  # effective_for — inactive policies excluded

  test "effective_for excludes inactive policies" do
    create_policy(
      name: "inactive", priority: 0,
      scope_type: nil, scope_id: nil,
      active: false,
      net: { "mode" => "none" }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_empty result[:policy_ids]
  end

  # effective_for — other account's policies excluded

  test "effective_for excludes policies from other accounts" do
    other_account = Account.create!(name: "other-account")
    create_policy(
      name: "other-account-policy",
      account_id: other_account.id,
      scope_type: "Account", scope_id: other_account.id,
      net: { "mode" => "none" }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_empty result[:policy_ids]
  end

  # effective_for — facility-scoped policy

  test "effective_for applies facility-scoped policy" do
    policy = create_policy(
      name: "facility-policy", priority: 20,
      scope_type: "Conduits::Facility", scope_id: @facility.id,
      sandbox_profile_rules: { "allow_host" => false }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_includes result[:policy_ids], policy.id
    assert_equal({ "allow_host" => false }, result[:sandbox_profile_rules])
  end

  # ─── Device dimension ─────────────────────────────────────

  test "validate_device_structure rejects unknown keys" do
    policy = Conduits::Policy.new(
      account: @account, name: "bad-device", priority: 0,
      device: { "allowed" => ["camera.*"], "badkey" => ["x"] }
    )
    refute policy.valid?
    assert policy.errors[:device].any? { |e| e.include?("unknown keys") }
  end

  test "validate_device_structure rejects non-array values" do
    policy = Conduits::Policy.new(
      account: @account, name: "bad-device2", priority: 0,
      device: { "allowed" => "camera.*" }
    )
    refute policy.valid?
    assert policy.errors[:device].any? { |e| e.include?("must be an array") }
  end

  test "validate_device_structure accepts valid device policy" do
    policy = Conduits::Policy.new(
      account: @account, name: "good-device", priority: 0,
      device: { "allowed" => ["camera.*"], "denied" => ["camera.record"], "approval_required" => ["sms.send"] }
    )
    assert policy.valid?
  end

  test "effective_for includes device dimension in merge" do
    create_policy(
      name: "global-device", priority: 0,
      scope_type: nil, scope_id: nil,
      device: { "allowed" => ["camera.*", "audio.*"], "denied" => ["sms.send"] }
    )
    create_policy(
      name: "account-device", priority: 10,
      scope_type: "Account", scope_id: @account.id,
      device: { "allowed" => ["camera.snap"], "approval_required" => ["camera.snap"] }
    )

    result = Conduits::Policy.effective_for(@directive)

    # allowed: intersection of ["camera.*", "audio.*"] and ["camera.snap"] = ["camera.snap"]
    assert_includes result[:device]["allowed"], "camera.snap"
    refute_includes(result[:device]["allowed"] || [], "audio.record")
    # denied: union
    assert_includes result[:device]["denied"], "sms.send"
    # approval_required: union
    assert_includes result[:device]["approval_required"], "camera.snap"
  end

  test "effective_for returns empty device when no device policies" do
    create_policy(
      name: "no-device", priority: 0,
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"] }
    )

    result = Conduits::Policy.effective_for(@directive)
    assert_equal({}, result[:device])
  end

  private

  def create_policy(name:, priority: 0, scope_type: nil, scope_id: nil, active: true, account_id: nil, **caps)
    Conduits::Policy.create!(
      account_id: account_id || @account.id,
      name: name,
      priority: priority,
      scope_type: scope_type,
      scope_id: scope_id,
      active: active,
      fs: caps[:fs] || {},
      net: caps[:net] || {},
      secrets: caps[:secrets] || {},
      sandbox_profile_rules: caps[:sandbox_profile_rules] || {},
      approval: caps[:approval] || {},
      device: caps[:device] || {}
    )
  end
end
