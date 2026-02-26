require "test_helper"

class ConduitsCommandPolicyE2ETest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
    Conduits::AuditEvent.delete_all
    Conduits::Command.find_each { |c| c.result_attachment.purge if c.result_attachment.attached? }
    Conduits::Command.delete_all
    Conduits::BridgeEntity.delete_all
    Conduits::LogChunk.delete_all
    Conduits::Directive.find_each { |d| d.diff_blob.purge if d.diff_blob.attached? }
    Conduits::Directive.delete_all
    Conduits::Policy.delete_all
    Conduits::Facility.delete_all
    Conduits::EnrollmentToken.delete_all
    Conduits::Territory.delete_all
    User.delete_all
    Account.delete_all
  end

  test "command creation via API: allowed capability dispatches immediately" do
    setup_territory_with_policy(
      device: { "allowed" => ["camera.*", "location.get"] }
    )

    post "/mothership/api/v1/commands",
         params: {
           capability: "camera.snap",
           params: { facing: "back" },
           target: { territory_id: @territory.id },
           timeout_seconds: 30,
         },
         headers: auth_headers,
         as: :json

    assert_response 201
    body = JSON.parse(response.body)
    assert_equal "queued", body["state"]
    assert body["command_id"].present?

    cmd = Conduits::Command.find(body["command_id"])
    assert cmd.policy_snapshot.present?
  end

  test "command creation via API: denied capability returns 403" do
    setup_territory_with_policy(
      device: { "allowed" => ["camera.*"], "denied" => ["camera.record"] }
    )

    post "/mothership/api/v1/commands",
         params: {
           capability: "camera.record",
           params: {},
           target: { territory_id: @territory.id },
           timeout_seconds: 30,
         },
         headers: auth_headers,
         as: :json

    assert_response 403
    body = JSON.parse(response.body)
    assert_equal "policy_denied", body["error"]
  end

  test "command creation via API: needs_approval enters awaiting_approval" do
    setup_territory_with_policy(
      device: { "allowed" => ["*"], "approval_required" => ["iot.lock.control"] }
    )

    post "/mothership/api/v1/commands",
         params: {
           capability: "iot.lock.control",
           params: { action: "unlock" },
           target: { territory_id: @territory.id },
           timeout_seconds: 60,
         },
         headers: auth_headers,
         as: :json

    assert_response 202
    body = JSON.parse(response.body)
    assert_equal "awaiting_approval", body["state"]
    assert body["approval_reasons"].present?

    cmd = Conduits::Command.find(body["command_id"])
    assert_equal "awaiting_approval", cmd.state
    assert cmd.policy_snapshot.present?
  end

  test "approve/reject workflow for commands" do
    setup_territory_with_policy(
      device: { "allowed" => ["*"], "approval_required" => ["sms.send"] }
    )

    # Create command that needs approval
    post "/mothership/api/v1/commands",
         params: {
           capability: "sms.send",
           params: { to: "+1234567890", body: "Hello" },
           target: { territory_id: @territory.id },
           timeout_seconds: 30,
         },
         headers: auth_headers,
         as: :json

    assert_response 202
    command_id = JSON.parse(response.body)["command_id"]

    # Cannot approve own command
    post "/mothership/api/v1/commands/#{command_id}/approve",
         headers: auth_headers,
         as: :json

    assert_response 403

    # Different user approves
    post "/mothership/api/v1/commands/#{command_id}/approve",
         headers: approver_headers,
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal "queued", body["state"]

    cmd = Conduits::Command.find(command_id)
    assert_equal "queued", cmd.state
    assert_equal @approver.id, cmd.approved_by_user_id
  end

  test "reject workflow for commands" do
    setup_territory_with_policy(
      device: { "allowed" => ["*"], "approval_required" => ["sms.send"] }
    )

    post "/mothership/api/v1/commands",
         params: {
           capability: "sms.send",
           params: { to: "+1234567890" },
           target: { territory_id: @territory.id },
           timeout_seconds: 30,
         },
         headers: auth_headers,
         as: :json

    assert_response 202
    command_id = JSON.parse(response.body)["command_id"]

    post "/mothership/api/v1/commands/#{command_id}/reject",
         headers: approver_headers,
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal "canceled", body["state"]
  end

  test "command with no device policies passes through (backwards compatible)" do
    setup_territory_without_policy

    post "/mothership/api/v1/commands",
         params: {
           capability: "camera.snap",
           params: {},
           target: { territory_id: @territory.id },
           timeout_seconds: 30,
         },
         headers: auth_headers,
         as: :json

    assert_response 201
    body = JSON.parse(response.body)
    assert_equal "queued", body["state"]
  end

  test "result_hash idempotency on command result" do
    setup_territory_without_policy

    cmd = Conduits::Command.create!(
      account: @account, territory: @territory,
      capability: "camera.snap", timeout_seconds: 30
    )
    cmd.dispatch!

    # First result
    post "/conduits/v1/commands/#{cmd.id}/result",
         params: { status: "completed", result: { width: 100 } },
         headers: { "X-Nexus-Territory-Id" => @territory.id },
         as: :json

    assert_response 200
    refute JSON.parse(response.body)["duplicate"]

    cmd.reload
    assert cmd.result_hash.present?

    # Identical retry → duplicate
    post "/conduits/v1/commands/#{cmd.id}/result",
         params: { status: "completed", result: { width: 100 } },
         headers: { "X-Nexus-Territory-Id" => @territory.id },
         as: :json

    assert_response 200
    assert JSON.parse(response.body)["duplicate"]

    # Mismatched retry → conflict
    post "/conduits/v1/commands/#{cmd.id}/result",
         params: { status: "completed", result: { width: 999 } },
         headers: { "X-Nexus-Territory-Id" => @territory.id },
         as: :json

    assert_response 409
  end

  test "territory heartbeat with runtime_status" do
    setup_territory_without_policy

    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.7.0",
           runtime_status: {
             running_directives: 2,
             running_commands: 1,
             directive_ids: ["uuid-1", "uuid-2"],
             uptime_seconds: 3600,
           },
         },
         headers: { "X-Nexus-Territory-Id" => @territory.id },
         as: :json

    assert_response 200

    @territory.reload
    assert_equal 2, @territory.runtime_status["running_directives"]
    assert_equal 1, @territory.runtime_status["running_commands"]
    assert_equal 3600, @territory.runtime_status["uptime_seconds"]
  end

  private

  def setup_territory_with_policy(device:)
    @account = Account.create!(name: "policy-e2e")
    @user = User.create!(account: @account, name: "requester")
    @approver = User.create!(account: @account, name: "approver")

    _, token = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour
    )

    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: token, name: "test-mobile",
           kind: "mobile", platform: "ios",
         },
         as: :json

    @territory = Conduits::Territory.find(JSON.parse(response.body)["territory_id"])

    # Set capabilities on territory
    @territory.update!(capabilities: ["camera.snap", "camera.record", "location.get",
                                       "sms.send", "iot.lock.control"])

    Conduits::Policy.create!(
      account: @account, name: "device-policy", priority: 0, device: device
    )
  end

  def setup_territory_without_policy
    @account = Account.create!(name: "nopolicy-e2e")
    @user = User.create!(account: @account, name: "requester")
    @approver = User.create!(account: @account, name: "approver")

    _, token = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour
    )

    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: token, name: "test-mobile",
           kind: "mobile", platform: "ios",
         },
         as: :json

    @territory = Conduits::Territory.find(JSON.parse(response.body)["territory_id"])
    @territory.update!(capabilities: ["camera.snap", "camera.record"])
  end

  def auth_headers
    { "X-Account-Id" => @account.id, "X-User-Id" => @user.id }
  end

  def approver_headers
    { "X-Account-Id" => @account.id, "X-User-Id" => @approver.id }
  end
end
