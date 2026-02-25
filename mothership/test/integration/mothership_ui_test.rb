require "test_helper"

class MothershipUiTest < ActionDispatch::IntegrationTest
  test "minimal UI renders and logs are queryable" do
    account = Account.create!(name: "ui-test-account")
    user = User.create!(account: account, name: "ui-test-user")
    territory = Conduits::Territory.create!(account: account, name: "ui-territory")
    facility = Conduits::Facility.create!(
      account: account,
      owner: user,
      territory: territory,
      kind: "repo",
      retention_policy: "keep_last_5",
      repo_url: "https://example.invalid/repo"
    )

    directive = Conduits::Directive.create!(
      account: account,
      facility: facility,
      requested_by_user: user,
      command: "echo ui-test",
      sandbox_profile: "untrusted",
      territory: territory
    )

    Conduits::LogChunk.create!(
      directive: directive,
      stream: "stdout",
      seq: 0,
      bytes: "hello\n".b,
      bytesize: 6,
      truncated: false
    )

    directive.diff_blob.attach(
      io: StringIO.new("diff\n"),
      filename: "diff.patch",
      content_type: "text/x-diff"
    )

    get "/mothership/territories"
    assert_response :success

    get "/mothership/directives"
    assert_response :success

    get "/mothership/directives/#{directive.id}"
    assert_response :success

    get "/mothership/directives/#{directive.id}/log", params: { stream: "stdout", after_seq: -1, limit: 10 }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal directive.id, body["directive_id"]
    assert_equal "stdout", body["stream"]
    assert_equal 1, body["chunks"].length
    assert_equal 0, body["chunks"][0]["seq"]
    assert_equal Base64.strict_encode64("hello\n"), body["chunks"][0]["bytes_base64"]

    get "/mothership/directives/#{directive.id}/log", params: { stream: "nope" }
    assert_response 422

    get "/mothership/directives/#{directive.id}/diff"
    assert_includes [200, 302], response.status
  end
end
