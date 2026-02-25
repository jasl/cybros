require "test_helper"

class Conduits::FacilityTest < ActiveSupport::TestCase
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
      command: "echo hi",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )
  end

  test "locked? returns false when no directive holds the lock" do
    assert_not @facility.locked?
  end

  test "lock! acquires the lock" do
    @facility.lock!(@directive)
    assert @facility.locked?
    assert_equal @directive.id, @facility.locked_by_directive_id
  end

  test "lock! is idempotent for same directive" do
    @facility.lock!(@directive)
    assert @facility.lock!(@directive) # should not raise
    assert_equal @directive.id, @facility.locked_by_directive_id
  end

  test "lock! raises when locked by another directive" do
    @facility.lock!(@directive)

    other_directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo other",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )

    assert_raises(Conduits::Facility::LockConflict) do
      @facility.lock!(other_directive)
    end
  end

  test "lock! uses atomic UPDATE to prevent race conditions" do
    # Simulate concurrent lock attempt by directly updating the DB
    other_directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo race",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )

    # First lock succeeds
    @facility.lock!(@directive)

    # Simulate stale object that doesn't know about the lock
    stale_facility = Conduits::Facility.find(@facility.id)
    assert_raises(Conduits::Facility::LockConflict) do
      stale_facility.lock!(other_directive)
    end
  end

  test "unlock! releases the lock" do
    @facility.lock!(@directive)
    @facility.unlock!
    assert_not @facility.locked?
    assert_nil @facility.locked_by_directive_id
  end
end
