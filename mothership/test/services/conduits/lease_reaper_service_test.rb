require "test_helper"

class Conduits::LeaseReaperServiceTest < ActiveSupport::TestCase
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

  test "reaps expired leased directives back to queued" do
    directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )
    directive.territory = @territory
    directive.lease_expires_at = 10.minutes.from_now
    directive.lease!

    # Force the lease to be expired
    directive.update_columns(lease_expires_at: 1.minute.ago)

    # Lock the facility
    @facility.lock!(directive)

    Conduits::LeaseReaperService.new.call

    directive.reload
    assert directive.queued?
    assert_nil directive.territory_id

    @facility.reload
    assert_not @facility.locked?
  end

  test "does not reap non-expired leases" do
    directive = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )
    directive.territory = @territory
    directive.lease_expires_at = 10.minutes.from_now
    directive.lease!

    Conduits::LeaseReaperService.new.call

    directive.reload
    assert directive.leased?
  end
end
