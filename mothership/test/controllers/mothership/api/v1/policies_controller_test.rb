require "test_helper"

class Mothership::API::V1::PoliciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "test-account")
    @user = User.create!(account: @account, name: "test-user")
  end

  # --- Index ---

  test "index lists policies for current account" do
    policy = create_policy(name: "test-policy")
    other_account = Account.create!(name: "other")
    Conduits::Policy.create!(
      account: other_account, name: "other-policy", priority: 0
    )

    get policies_url, headers: auth_headers, as: :json

    assert_response :ok
    body = response.parsed_body
    ids = body["policies"].map { |p| p["id"] }
    assert_includes ids, policy.id
    assert_equal 1, ids.size
  end

  test "index filters by scope_type" do
    global = create_policy(name: "global", scope_type: nil, scope_id: nil)
    account_scoped = create_policy(
      name: "account-scoped",
      scope_type: "Account", scope_id: @account.id
    )

    get policies_url(scope_type: "Account"), headers: auth_headers, as: :json

    assert_response :ok
    body = response.parsed_body
    ids = body["policies"].map { |p| p["id"] }
    assert_includes ids, account_scoped.id
    assert_not_includes ids, global.id
  end

  test "index excludes inactive by default" do
    active = create_policy(name: "active")
    inactive = create_policy(name: "inactive")
    inactive.update!(active: false)

    get policies_url, headers: auth_headers, as: :json

    body = response.parsed_body
    ids = body["policies"].map { |p| p["id"] }
    assert_includes ids, active.id
    assert_not_includes ids, inactive.id
  end

  test "index includes inactive when requested" do
    active = create_policy(name: "active")
    inactive = create_policy(name: "inactive")
    inactive.update!(active: false)

    get policies_url(include_inactive: "true"), headers: auth_headers, as: :json

    body = response.parsed_body
    ids = body["policies"].map { |p| p["id"] }
    assert_includes ids, active.id
    assert_includes ids, inactive.id
  end

  # --- Show ---

  test "show returns policy details" do
    policy = create_policy(
      name: "detailed",
      fs: { "read" => ["/workspace"], "write" => [] },
      net: { "mode" => "none" },
      approval: { "host_profile" => "forbidden" }
    )

    get policy_url(policy), headers: auth_headers, as: :json

    assert_response :ok
    body = response.parsed_body
    assert_equal "detailed", body["name"]
    assert_equal({ "read" => ["/workspace"], "write" => [] }, body["fs"])
    assert_equal({ "mode" => "none" }, body["net"])
    assert_equal({ "host_profile" => "forbidden" }, body["approval"])
  end

  test "show returns not_found for other account policy" do
    other_account = Account.create!(name: "other")
    policy = Conduits::Policy.create!(
      account: other_account, name: "other-policy", priority: 0
    )

    get policy_url(policy), headers: auth_headers, as: :json

    assert_response :not_found
  end

  # --- Create ---

  test "create a new policy" do
    post policies_url,
      params: {
        name: "new-policy",
        priority: 10,
        fs: { read: ["/workspace"], write: ["/workspace"] },
        net: { mode: "allowlist", allow: ["api.example.com:443"] },
        approval: { host_profile: "needs_approval" },
      },
      headers: auth_headers,
      as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal "new-policy", body["name"]
    assert_equal 10, body["priority"]
    assert_equal @account.id, Conduits::Policy.find(body["id"]).account_id
  end

  test "create with scope" do
    post policies_url,
      params: {
        name: "account-policy",
        priority: 5,
        scope_type: "Account",
        scope_id: @account.id,
      },
      headers: auth_headers,
      as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal "Account", body["scope_type"]
    assert_equal @account.id, body["scope_id"]
  end

  test "create with missing name returns validation error" do
    post policies_url,
      params: { priority: 0 },
      headers: auth_headers,
      as: :json

    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "validation_failed", body["error"]
  end

  # --- Update ---

  test "update modifies policy fields" do
    policy = create_policy(name: "original")

    patch policy_url(policy),
      params: { name: "updated", priority: 99, approval: { host_profile: "forbidden" } },
      headers: auth_headers,
      as: :json

    assert_response :ok
    body = response.parsed_body
    assert_equal "updated", body["name"]
    assert_equal 99, body["priority"]

    policy.reload
    assert_equal "updated", policy.name
    assert_equal({ "host_profile" => "forbidden" }, policy.approval)
  end

  # --- Destroy (soft-delete) ---

  test "destroy soft-deletes policy" do
    policy = create_policy(name: "to-delete")
    assert policy.active?

    delete policy_url(policy), headers: auth_headers, as: :json

    assert_response :ok
    body = response.parsed_body
    assert_equal false, body["active"]

    policy.reload
    assert_not policy.active?
  end

  # --- Auth ---

  test "unauthenticated request returns unauthorized" do
    get policies_url, as: :json

    assert_response :unauthorized
  end

  private

  def auth_headers
    {
      "X-Account-Id" => @account.id,
      "X-User-Id" => @user.id,
    }
  end

  def policies_url(**query)
    uri = "/mothership/api/v1/policies"
    uri += "?#{query.to_query}" if query.any?
    uri
  end

  def policy_url(policy)
    "/mothership/api/v1/policies/#{policy.id}"
  end

  def create_policy(name: "test-policy", **attrs)
    Conduits::Policy.create!(
      account: @account,
      name: name,
      priority: attrs.delete(:priority) || 0,
      **attrs
    )
  end
end
