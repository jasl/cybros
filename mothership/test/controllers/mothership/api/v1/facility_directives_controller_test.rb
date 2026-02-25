require "test_helper"

class Mothership::API::V1::FacilityDirectivesControllerTest < ActionDispatch::IntegrationTest
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

  # --- 2a.6: PolicyResolver wired into create ---

  test "create with no policies returns queued with defaults" do
    post facility_directives_url,
      params: { command: "echo hello", sandbox_profile: "untrusted" },
      headers: auth_headers,
      as: :json

    assert_response :created
    body = response.parsed_body

    assert_equal "queued", body["state"]
    assert body["directive_id"].present?

    directive = Conduits::Directive.find(body["directive_id"])
    assert directive.effective_capabilities.present?
    assert directive.effective_capabilities["fs"].present?
    assert directive.policy_snapshot.present?
  end

  test "create with forbidden policy returns 403" do
    Conduits::Policy.create!(
      account: @account,
      name: "forbid-host",
      scope_type: nil, scope_id: nil,
      priority: 0,
      approval: { "host_profile" => "forbidden" }
    )

    post facility_directives_url,
      params: { command: "echo test", sandbox_profile: "host" },
      headers: auth_headers,
      as: :json

    assert_response :forbidden
    body = response.parsed_body

    assert_equal "policy_forbidden", body["error"]
    assert body["reasons"].present?

    # No directive should be created
    assert_equal 0, Conduits::Directive.count
  end

  test "create with needs_approval policy returns 202 awaiting_approval" do
    Conduits::Policy.create!(
      account: @account,
      name: "approve-host",
      scope_type: nil, scope_id: nil,
      priority: 0,
      approval: { "host_profile" => "needs_approval" }
    )

    post facility_directives_url,
      params: { command: "echo test", sandbox_profile: "host" },
      headers: auth_headers,
      as: :json

    assert_response :accepted
    body = response.parsed_body

    assert_equal "awaiting_approval", body["state"]
    assert body["approval_reasons"].present?
    assert body["directive_id"].present?

    directive = Conduits::Directive.find(body["directive_id"])
    assert directive.awaiting_approval?
    assert directive.effective_capabilities.present?
    assert directive.policy_snapshot.present?
  end

  test "create caps effective_capabilities via restrictive net policy" do
    Conduits::Policy.create!(
      account: @account,
      name: "restrict-net",
      scope_type: nil, scope_id: nil,
      priority: 0,
      net: { "mode" => "none" }
    )

    post facility_directives_url,
      params: {
        command: "curl example.com",
        sandbox_profile: "untrusted",
        requested_capabilities: { net: { mode: "unrestricted" } },
      },
      headers: auth_headers,
      as: :json

    assert_response :created
    body = response.parsed_body
    directive = Conduits::Directive.find(body["directive_id"])

    # Policy caps net to "none" even though request asked for "unrestricted"
    assert_equal "none", directive.effective_capabilities.dig("net", "mode")
  end

  test "create narrows requested FS via policy ceiling" do
    Conduits::Policy.create!(
      account: @account,
      name: "restrict-fs",
      scope_type: nil, scope_id: nil,
      priority: 0,
      fs: { "read" => ["/workspace/src"], "write" => [] }
    )

    post facility_directives_url,
      params: {
        command: "cat file.txt",
        sandbox_profile: "untrusted",
        requested_capabilities: {
          fs: { read: ["/workspace"], write: ["/workspace"] },
        },
      },
      headers: auth_headers,
      as: :json

    assert_response :created
    body = response.parsed_body
    directive = Conduits::Directive.find(body["directive_id"])

    # Policy FS is narrower — intersect means read only /workspace/src, write empty
    effective_fs = directive.effective_capabilities["fs"]
    assert_includes effective_fs["read"], "/workspace/src"
    assert_empty effective_fs["write"]
  end

  # --- 2a.7: Approval endpoints ---

  test "approve transitions awaiting_approval to queued" do
    directive = create_awaiting_directive
    approver = User.create!(account: @account, name: "approver-user")

    post approve_directive_url(directive),
      headers: { "X-Account-Id" => @account.id, "X-User-Id" => approver.id },
      as: :json

    assert_response :ok
    body = response.parsed_body

    assert_equal "queued", body["state"]
    assert_equal approver.id, body["approved_by_user_id"]

    directive.reload
    assert directive.queued?
    assert_equal approver.id, directive.approved_by_user_id
  end

  test "SECURITY: self-approval is forbidden" do
    directive = create_awaiting_directive

    # @user created the directive — cannot approve their own
    post approve_directive_url(directive),
      headers: auth_headers,
      as: :json

    assert_response :forbidden
    body = response.parsed_body
    assert_equal "forbidden", body["error"]
    assert_match(/cannot approve own/, body["detail"])

    directive.reload
    assert directive.awaiting_approval?, "directive should remain awaiting_approval"
  end

  test "reject transitions awaiting_approval to canceled" do
    directive = create_awaiting_directive

    post reject_directive_url(directive),
      headers: auth_headers,
      as: :json

    assert_response :ok
    body = response.parsed_body

    assert_equal "canceled", body["state"]

    directive.reload
    assert directive.canceled?
  end

  test "approve on queued directive returns conflict" do
    directive = Conduits::Directive.create!(
      account: @account, facility: @facility, requested_by_user: @user,
      command: "echo hello", sandbox_profile: "untrusted", timeout_seconds: 60
    )
    other_user = User.create!(account: @account, name: "other-approver")

    post approve_directive_url(directive),
      headers: { "X-Account-Id" => @account.id, "X-User-Id" => other_user.id },
      as: :json

    assert_response :conflict
    body = response.parsed_body
    assert_equal "state_conflict", body["error"]
  end

  test "reject on queued directive returns conflict" do
    directive = Conduits::Directive.create!(
      account: @account, facility: @facility, requested_by_user: @user,
      command: "echo hello", sandbox_profile: "untrusted", timeout_seconds: 60
    )

    post reject_directive_url(directive),
      headers: auth_headers,
      as: :json

    assert_response :conflict
  end

  test "approve sets approved_by_user to current user" do
    directive = create_awaiting_directive
    other_user = User.create!(account: @account, name: "approver")

    post approve_directive_url(directive),
      headers: { "X-Account-Id" => @account.id, "X-User-Id" => other_user.id },
      as: :json

    assert_response :ok

    directive.reload
    assert_equal other_user.id, directive.approved_by_user_id
  end

  # --- 2c.1: CommandValidator integration ---

  test "create with forbidden command returns 422 for host profile" do
    post facility_directives_url,
      params: { command: "sudo rm -rf /", sandbox_profile: "host" },
      headers: auth_headers,
      as: :json

    assert_response :unprocessable_entity
    body = response.parsed_body

    assert_equal "command_forbidden", body["error"]
    assert body["violations"].present?

    # No directive should be created
    assert_equal 0, Conduits::Directive.count
  end

  test "create with dangerous command on untrusted profile passes (sandbox enforces)" do
    post facility_directives_url,
      params: { command: "sudo rm -rf /", sandbox_profile: "untrusted" },
      headers: auth_headers,
      as: :json

    assert_response :created
    assert_equal "queued", response.parsed_body["state"]
  end

  test "create with pipe command on host profile and skip policy triggers needs_approval" do
    post facility_directives_url,
      params: { command: "cat file.txt | grep pattern", sandbox_profile: "host" },
      headers: auth_headers,
      as: :json

    # Command validator says needs_approval, policy says skip → combined = needs_approval
    assert_response :accepted
    body = response.parsed_body
    assert_equal "awaiting_approval", body["state"]
    assert body["approval_reasons"].any? { |r| r.include?("pipe") }
  end

  test "create with safe command on host profile is queued" do
    post facility_directives_url,
      params: { command: "echo hello world", sandbox_profile: "host" },
      headers: auth_headers,
      as: :json

    assert_response :created
    assert_equal "queued", response.parsed_body["state"]
  end

  # --- Auth guards ---

  test "create without auth headers returns unauthorized" do
    post facility_directives_url,
      params: { command: "echo hello" },
      as: :json

    assert_response :unauthorized
  end

  private

  def auth_headers
    {
      "X-Account-Id" => @account.id,
      "X-User-Id" => @user.id,
    }
  end

  def facility_directives_url
    "/mothership/api/v1/facilities/#{@facility.id}/directives"
  end

  def approve_directive_url(directive)
    "/mothership/api/v1/facilities/#{@facility.id}/directives/#{directive.id}/approve"
  end

  def reject_directive_url(directive)
    "/mothership/api/v1/facilities/#{@facility.id}/directives/#{directive.id}/reject"
  end

  def create_awaiting_directive
    directive = Conduits::Directive.new(
      account: @account,
      facility: @facility,
      requested_by_user: @user,
      command: "echo hello",
      sandbox_profile: "untrusted",
      timeout_seconds: 60,
      effective_capabilities: { "fs" => { "read" => ["/workspace"], "write" => ["/workspace"] } },
      policy_snapshot: { "resolved_at" => Time.current.iso8601, "policies_applied" => [] }
    )
    directive.state = "awaiting_approval"
    directive.save!
    directive
  end
end
