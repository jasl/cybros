require "test_helper"

class Conduits::PollServiceTest < ActiveSupport::TestCase
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

  test "assigns queued directives to territory" do
    directive = create_directive

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal 1, result.directives.size
    assert_equal directive.id, result.directives.first[:directive_id]
    assert result.directives.first[:directive_token].present?

    directive.reload
    assert directive.leased?
    assert_equal @territory.id, directive.territory_id
  end

  test "returns empty when no matching directives" do
    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_empty result.directives
    assert_equal Conduits::PollService::DEFAULT_RETRY_AFTER, result.retry_after_seconds
  end

  test "respects sandbox_profile filter" do
    create_directive(sandbox_profile: "host")

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_empty result.directives
  end

  test "skips locked facility" do
    directive = create_directive
    other_directive = create_directive

    @facility.lock!(other_directive)

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 5
    ).call

    # Only the directive whose facility is locked by itself (or unlocked) should be leased
    leased_ids = result.directives.map { |d| d[:directive_id] }
    assert_not_includes leased_ids, directive.id
  end

  test "caps max_claims at 5" do
    6.times { create_directive }

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 10
    ).call

    assert result.directives.size <= 5
  end

  test "locks facility when leasing" do
    create_directive

    Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    @facility.reload
    assert @facility.locked?
  end

  test "reverts lease if facility lock fails" do
    directive = create_directive

    # Simulate a facility-lock race by forcing lock! to raise after the directive is leased.
    Conduits::Facility.class_eval do
      alias_method :__orig_lock_for_test!, :lock!
      define_method(:lock!) { |_d| raise Conduits::Facility::LockConflict, "Facility already locked" }
    end

    begin
      result = Conduits::PollService.new(
        territory: @territory,
        supported_profiles: %w[untrusted],
        max_claims: 1
      ).call

      assert_empty result.directives

      directive.reload
      assert directive.queued?
      assert_nil directive.territory_id
      assert_nil directive.lease_expires_at
    ensure
      Conduits::Facility.class_eval do
        alias_method :lock!, :__orig_lock_for_test!
        remove_method :__orig_lock_for_test!
      end
    end
  end

  test "skips directive when territory sandbox is unhealthy for profile" do
    create_directive(sandbox_profile: "untrusted")

    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true },
        "bwrap" => { "healthy" => false, "details" => { "error" => "namespace test failed" } }
      }
    }
    @territory.save!

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_empty result.directives
  end

  test "assigns directive when territory sandbox is healthy for profile" do
    directive = create_directive(sandbox_profile: "untrusted")

    @territory.capacity = {
      "sandbox_health" => {
        "host" => { "healthy" => true },
        "bwrap" => { "healthy" => true }
      }
    }
    @territory.save!

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal 1, result.directives.size
    assert_equal directive.id, result.directives.first[:directive_id]
  end

  test "assigns directive when no health data available" do
    directive = create_directive(sandbox_profile: "untrusted")

    # No capacity set at all — should default to healthy (graceful startup)
    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal 1, result.directives.size
    assert_equal directive.id, result.directives.first[:directive_id]
  end

  # --- 2a.8: Lease-time policy re-validation ---

  test "re-validation: cancels directive when policy becomes forbidden at lease time" do
    directive = create_directive(sandbox_profile: "host")

    # Add a policy that makes host profile forbidden
    Conduits::Policy.create!(
      account: @account,
      name: "forbid-host",
      scope_type: nil, scope_id: nil,
      priority: 0,
      approval: { "host_profile" => "forbidden" }
    )

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[host],
      max_claims: 1
    ).call

    assert_empty result.directives

    directive.reload
    assert directive.canceled?
  end

  test "re-validation: updates effective_capabilities when policy changes" do
    directive = create_directive
    original_caps = directive.effective_capabilities.deep_dup

    # Add a policy that narrows FS access
    Conduits::Policy.create!(
      account: @account,
      name: "narrow-fs",
      scope_type: nil, scope_id: nil,
      priority: 0,
      fs: { "read" => ["/workspace/src"], "write" => [] }
    )

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal 1, result.directives.size

    directive.reload
    assert directive.leased?
    # FS should now be narrowed by policy
    assert_not_equal original_caps, directive.effective_capabilities
    assert_equal ["/workspace/src"], directive.effective_capabilities.dig("fs", "read")
    assert_equal [], directive.effective_capabilities.dig("fs", "write")
  end

  test "re-validation: normal lease when no policy changes" do
    directive = create_directive

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal 1, result.directives.size
    assert_equal directive.id, result.directives.first[:directive_id]

    directive.reload
    assert directive.leased?
  end

  # --- Security regression tests ---

  test "SECURITY: territory cannot claim directives from another account" do
    other_account = Account.create!(name: "other-account")
    other_user = User.create!(account: other_account, name: "other-user")
    other_territory = Conduits::Territory.create!(account: other_account, name: "other-territory")
    other_territory.activate!
    other_facility = Conduits::Facility.create!(
      account: other_account,
      owner: other_user,
      territory: other_territory,
      kind: "repo",
      retention_policy: "keep_last_5"
    )
    Conduits::Directive.create!(
      account: other_account,
      facility: other_facility,
      requested_by_user: other_user,
      command: "echo cross-account-attack",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )

    # Our territory should NOT see directives from other_account
    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 5
    ).call

    assert_empty result.directives
  end

  test "SECURITY: LockConflict is raised instead of generic RuntimeError" do
    create_directive
    other_directive = create_directive
    @facility.lock!(other_directive)

    assert_raises(Conduits::Facility::LockConflict) do
      @facility.lock!(create_directive)
    end
  end

  test "lease_ttl_seconds is set" do
    create_directive

    result = Conduits::PollService.new(
      territory: @territory,
      supported_profiles: %w[untrusted],
      max_claims: 1
    ).call

    assert_equal Conduits::PollService::DEFAULT_LEASE_TTL, result.lease_ttl_seconds
  end

  private

  def create_directive(sandbox_profile: "untrusted")
    Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: sandbox_profile,
      timeout_seconds: 60
    )
  end
end
