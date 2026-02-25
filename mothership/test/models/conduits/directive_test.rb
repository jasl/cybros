require "test_helper"

class Conduits::DirectiveTest < ActiveSupport::TestCase
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

  # State machine transitions

  test "initial state is queued" do
    assert @directive.queued?
  end

  test "lease transitions from queued to leased" do
    @directive.territory = @territory
    @directive.lease!
    assert @directive.leased?
  end

  test "lease requires territory" do
    assert_raises(AASM::InvalidTransition) { @directive.lease! }
  end

  test "start transitions from leased to running" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!
    assert @directive.running?
  end

  test "start from queued raises" do
    assert_raises(AASM::InvalidTransition) { @directive.start! }
  end

  test "succeed transitions from running to succeeded" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!
    @directive.succeed!
    assert @directive.succeeded?
  end

  test "fail transitions from running to failed" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!
    @directive.fail!
    assert @directive.failed?
  end

  test "cancel transitions from queued to canceled" do
    @directive.cancel!
    assert @directive.canceled?
  end

  test "cancel transitions from leased to canceled" do
    @directive.territory = @territory
    @directive.lease!
    @directive.cancel!
    assert @directive.canceled?
  end

  test "cancel transitions from running to canceled" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!
    @directive.cancel!
    assert @directive.canceled?
  end

  test "time_out transitions from running to timed_out" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!
    @directive.time_out!
    assert @directive.timed_out?
  end

  test "expire_lease transitions from leased to queued and clears fields" do
    @directive.territory = @territory
    @directive.lease_expires_at = 10.minutes.from_now
    @directive.lease!

    @directive.expire_lease!

    assert @directive.queued?
    assert_nil @directive.territory_id
    assert_nil @directive.lease_expires_at
    assert_nil @directive.last_heartbeat_at
  end

  # Lease methods

  test "renew_lease! updates expiry and heartbeat" do
    @directive.territory = @territory
    @directive.lease!
    @directive.start!

    @directive.renew_lease!(ttl_seconds: 300)

    assert @directive.lease_expires_at > Time.current
    assert @directive.last_heartbeat_at.present?
  end

  test "lease_expired? returns true when lease has passed" do
    @directive.territory = @territory
    @directive.lease_expires_at = 1.minute.ago
    @directive.lease!

    assert @directive.lease_expired?
  end

  # cancel_requested?

  test "cancel_requested? returns false by default" do
    assert_not @directive.cancel_requested?
  end

  test "request_cancel! sets cancel_requested_at" do
    @directive.request_cancel!
    assert @directive.cancel_requested?
    assert @directive.cancel_requested_at.present?
  end

  test "request_cancel! is idempotent" do
    @directive.request_cancel!
    first_time = @directive.cancel_requested_at

    travel 1.minute do
      @directive.request_cancel!
      assert_equal first_time, @directive.cancel_requested_at
    end
  end

  # Limits helpers

  test "max_output_bytes defaults to 2MB" do
    assert_equal 2_000_000, @directive.max_output_bytes
  end

  test "max_output_bytes uses limits when set" do
    @directive.limits = { "max_output_bytes" => 5_000_000 }
    assert_equal 5_000_000, @directive.max_output_bytes
  end

  test "max_diff_bytes defaults to 1MB" do
    assert_equal 1_048_576, @directive.max_diff_bytes
  end

  # Approval transitions

  test "approve transitions from awaiting_approval to queued" do
    directive = create_awaiting_directive
    directive.approve!
    assert directive.queued?
  end

  test "reject transitions from awaiting_approval to canceled" do
    directive = create_awaiting_directive
    directive.reject!
    assert directive.canceled?
  end

  test "cancel transitions from awaiting_approval to canceled" do
    directive = create_awaiting_directive
    directive.cancel!
    assert directive.canceled?
  end

  test "lease from awaiting_approval raises" do
    directive = create_awaiting_directive
    directive.territory = @territory
    assert_raises(AASM::InvalidTransition) { directive.lease! }
  end

  test "start from awaiting_approval raises" do
    directive = create_awaiting_directive
    assert_raises(AASM::InvalidTransition) { directive.start! }
  end

  # Scopes

  test "pending_approval scope returns only awaiting_approval directives" do
    awaiting = create_awaiting_directive

    pending = Conduits::Directive.pending_approval
    assert_includes pending, awaiting
    assert_not_includes pending, @directive  # @directive is queued
  end

  test "assignable scope excludes awaiting_approval directives" do
    awaiting = create_awaiting_directive

    assignable = Conduits::Directive.assignable
    assert_includes assignable, @directive  # queued
    assert_not_includes assignable, awaiting
  end

  test "assignable scope returns only queued directives" do
    @directive.territory = @territory
    @directive.lease!

    queued = Conduits::Directive.create!(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo queued",
      sandbox_profile: "untrusted",
      timeout_seconds: 60
    )

    assignable = Conduits::Directive.assignable
    assert_includes assignable, queued
    assert_not_includes assignable, @directive
  end

  test "with_expired_lease scope returns only expired leased directives" do
    @directive.territory = @territory
    @directive.lease_expires_at = 10.minutes.from_now
    @directive.lease!
    @directive.update_columns(lease_expires_at: 1.minute.ago)

    expired = Conduits::Directive.with_expired_lease
    assert_includes expired, @directive
  end

  private

  def create_awaiting_directive
    directive = Conduits::Directive.new(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo awaiting",
      sandbox_profile: "untrusted",
      timeout_seconds: 60,
      effective_capabilities: { "fs" => { "read" => ["/workspace"], "write" => ["/workspace"] } }
    )
    directive.state = "awaiting_approval"
    directive.save!
    directive
  end
end
