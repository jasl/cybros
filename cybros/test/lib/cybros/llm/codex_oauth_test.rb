require "test_helper"

class Cybros::LLM::CodexOAuthTest < ActiveSupport::TestCase
  class FakeResponse
    attr_reader :status

    def initialize(status:, body:)
      @status = status
      @body = body
    end

    def to_s
      @body.to_s
    end
  end

  class FakeHTTP
    def initialize(responses)
      @responses = Array(responses)
      @calls = []
    end

    attr_reader :calls

    def with(headers:)
      @headers = headers
      self
    end

    def post(url, body:)
      @calls << { url: url, headers: @headers, body: body }
      @responses.shift || raise("no fake response configured")
    end
  end

  test "start_device_flow! parses device code response" do
    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 200,
            body: {
              device_auth_id: "dc",
              user_code: "uc",
              interval: 5,
              expires_at: "2026-03-05T20:59:51.659393+00:00",
            }.to_json,
          ),
        ]
      )

    flow = Cybros::LLM::CodexOAuth.start_device_flow!(http: http)
    assert_equal "dc", flow.fetch("device_auth_id")
    assert_equal "uc", flow.fetch("user_code")
  end

  test "poll_device_flow! returns pending for 403/404" do
    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 403,
            body: { error: "pending" }.to_json,
          ),
        ]
      )

    res = Cybros::LLM::CodexOAuth.poll_device_flow!(device_auth_id: "dc", user_code: "uc", http: http)
    assert_equal :pending, res.fetch(:status)
  end

  test "poll_device_flow! returns authorized tokens" do
    claims = { "workspace_id" => "ws_1" }
    jwt_payload = Base64.urlsafe_encode64(claims.to_json, padding: false)
    id_token = "header.#{jwt_payload}.sig"

    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 200,
            body: { authorization_code: "ac", code_verifier: "cv" }.to_json,
          ),
          FakeResponse.new(
            status: 200,
            body: { access_token: "at", refresh_token: "rt", expires_in: 3600, id_token: id_token }.to_json,
          ),
        ]
      )

    res = Cybros::LLM::CodexOAuth.poll_device_flow!(device_auth_id: "dc", user_code: "uc", http: http)
    assert_equal :authorized, res.fetch(:status)
    assert_equal "at", res.dig(:tokens, "access_token")
    assert_equal "rt", res.dig(:tokens, "refresh_token")
    assert res.dig(:tokens, "expires_at").is_a?(Time)
    assert_equal "ws_1", res.dig(:tokens, "account_id")
  end

  test "refresh_if_needed! refreshes expired credential and persists new tokens" do
    credential =
      LLMProvider.create!(
        provider_key: "codex_subscription",
        credential_type: "oauth_codex",
        access_token: "old-at",
        refresh_token: "old-rt",
        expires_at: Time.current - 60,
      )

    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 200,
            body: { access_token: "new-at", refresh_token: "new-rt", expires_in: 3600, account_id: "acc_1" }.to_json,
          ),
        ]
      )

    refreshed = Cybros::LLM::CodexOAuth.refresh_if_needed!(credential, http: http, now: Time.current, buffer_s: 60)

    assert_equal credential.id, refreshed.id
    credential.reload
    assert_equal "new-at", credential.access_token
    assert_equal "new-rt", credential.refresh_token
    assert_equal "acc_1", credential.account_id
    assert credential.expires_at > Time.current
  end

  test "refresh_if_needed! does not refresh a still-valid ActiveSupport time credential" do
    credential =
      LLMProvider.create!(
        provider_key: "codex_subscription",
        credential_type: "oauth_codex",
        access_token: "still-valid-at",
        refresh_token: "rt",
        expires_at: 2.hours.from_now,
      )

    http = FakeHTTP.new([])

    refreshed = Cybros::LLM::CodexOAuth.refresh_if_needed!(credential, http: http, now: Time.current, buffer_s: 60)

    assert_equal credential.id, refreshed.id
    assert_equal [], http.calls
    assert_equal "still-valid-at", credential.reload.access_token
  end

  test "start_device_flow! raises CodexOAuthError when required keys are missing" do
    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 200,
            body: {
              user_code: "uc",
              interval: 5,
            }.to_json,
          ),
        ]
      )

    error = assert_raises(Cybros::LLM::CodexOAuthError) { Cybros::LLM::CodexOAuth.start_device_flow!(http: http) }
    assert_includes error.message, "device_auth_id"
  end

  test "poll_device_flow! raises CodexOAuthError when token exchange keys are missing" do
    http =
      FakeHTTP.new(
        [
          FakeResponse.new(
            status: 200,
            body: { code_verifier: "cv" }.to_json,
          ),
        ]
      )

    error = assert_raises(Cybros::LLM::CodexOAuthError) do
      Cybros::LLM::CodexOAuth.poll_device_flow!(device_auth_id: "dc", user_code: "uc", http: http)
    end
    assert_includes error.message, "authorization_code"
  end
end
