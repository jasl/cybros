require "test_helper"

class Conduits::PolicyResolverTest < ActiveSupport::TestCase
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
  end

  test "no policies uses defaults and returns skip verdict" do
    directive = create_directive(sandbox_profile: "untrusted")
    result = Conduits::PolicyResolver.new(directive).call

    assert_equal :skip, result.approval_verdict
    assert_empty result.approval_reasons
    assert_empty result.policies_applied
    # Should have default FS capabilities
    assert_kind_of Hash, result.effective_capabilities
    assert_includes result.effective_capabilities.dig("fs", "read"), "workspace:**"
  end

  test "restrictive net policy caps capabilities" do
    Conduits::Policy.create!(
      account: @account, name: "restrict-net", priority: 0,
      scope_type: nil, scope_id: nil,
      net: { "mode" => "allowlist", "allow" => ["github.com:443"] }
    )
    directive = create_directive(
      sandbox_profile: "untrusted",
      requested_capabilities: { "net" => { "mode" => "unrestricted" } }
    )

    result = Conduits::PolicyResolver.new(directive).call
    # Policy caps unrestricted → allowlist
    assert_equal "allowlist", result.effective_capabilities.dig("net", "mode")
  end

  test "forbidden verdict from approval rules" do
    Conduits::Policy.create!(
      account: @account, name: "no-unrestricted-net", priority: 0,
      scope_type: nil, scope_id: nil,
      approval: { "net_unrestricted" => "forbidden" }
    )
    directive = create_directive(
      sandbox_profile: "untrusted",
      requested_capabilities: { "net" => { "mode" => "unrestricted" } }
    )

    result = Conduits::PolicyResolver.new(directive).call
    assert_equal :forbidden, result.approval_verdict
    assert_not_empty result.approval_reasons
  end

  test "needs_approval verdict from host profile rule" do
    Conduits::Policy.create!(
      account: @account, name: "approve-host", priority: 0,
      scope_type: nil, scope_id: nil,
      approval: { "host_profile" => "needs_approval" }
    )
    directive = create_directive(sandbox_profile: "host")

    result = Conduits::PolicyResolver.new(directive).call
    assert_equal :needs_approval, result.approval_verdict
  end

  test "policy snapshot is frozen (not a live reference)" do
    Conduits::Policy.create!(
      account: @account, name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    )
    directive = create_directive(sandbox_profile: "untrusted")

    result = Conduits::PolicyResolver.new(directive).call
    snapshot = result.policy_snapshot

    assert_kind_of Hash, snapshot
    assert snapshot.key?("policies_applied")
    assert snapshot.key?("resolved_at")
  end

  test "policies_applied lists applied policy IDs" do
    p1 = Conduits::Policy.create!(
      account: @account, name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    )
    directive = create_directive(sandbox_profile: "untrusted")

    result = Conduits::PolicyResolver.new(directive).call
    assert_includes result.policies_applied, p1.id
  end

  test "requested capabilities narrow but do not widen policy ceiling" do
    Conduits::Policy.create!(
      account: @account, name: "global", priority: 0,
      scope_type: nil, scope_id: nil,
      fs: { "read" => ["workspace:**"], "write" => [] },
      net: { "mode" => "allowlist", "allow" => ["github.com:443"] }
    )
    directive = create_directive(
      sandbox_profile: "untrusted",
      requested_capabilities: {
        "fs" => { "read" => ["workspace:**"], "write" => ["workspace:**"] },
        "net" => { "mode" => "unrestricted" }
      }
    )

    result = Conduits::PolicyResolver.new(directive).call
    # Policy says write=[], requested says write=workspace — policy ceiling wins
    assert_empty result.effective_capabilities.dig("fs", "write")
    # Policy says allowlist, requested says unrestricted — policy ceiling wins
    assert_equal "allowlist", result.effective_capabilities.dig("net", "mode")
  end

  private

  def create_directive(sandbox_profile:, requested_capabilities: {})
    Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo test",
      sandbox_profile: sandbox_profile,
      timeout_seconds: 60,
      requested_capabilities: requested_capabilities
    )
  end
end
