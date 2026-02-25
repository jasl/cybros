require "test_helper"
require "openssl"

class ConduitsE2ETest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
    # Clean up all records created during the test
    Conduits::AuditEvent.delete_all
    Conduits::LogChunk.delete_all
    Conduits::Directive.find_each { |d| d.diff_blob.purge if d.diff_blob.attached? }
    Conduits::Directive.delete_all
    Conduits::Facility.delete_all
    Conduits::EnrollmentToken.delete_all
    Conduits::Territory.delete_all
    User.delete_all
    Account.delete_all
  end

  test "full conduits lifecycle" do
    seed_data
    phase_enrollment
    phase_create_directive
    phase_poll_and_claim
    phase_started_report
    phase_directive_heartbeat
    phase_log_chunks
    phase_finished_report
    phase_query_directive
    phase_second_directive_cycle
    phase_lease_expiry_reaper
    phase_territory_heartbeat
    phase_edge_cases
  end

  private

  # ─── Seed Data ─────────────────────────────────────────────

  def seed_data
    @account = Account.create!(name: "e2e-test-account")
    @user = User.create!(account: @account, name: "e2e-test-user")
    @facility = Conduits::Facility.create!(
      account: @account,
      owner: @user,
      territory: Conduits::Territory.create!(account: @account, name: "seed-territory"),
      kind: "repo",
      retention_policy: "keep_last_5",
      repo_url: "https://github.com/example/test-repo"
    )

    @enrollment_record, @enrollment_token = Conduits::EnrollmentToken.generate!(
      account: @account,
      user: @user,
      ttl: 1.hour,
      labels: { env: "e2e-test" }
    )

    assert @account.persisted?, "Account created"
    assert @user.persisted?, "User created"
    assert @facility.persisted?, "Facility created"
    assert @enrollment_record.persisted?, "Enrollment token created"
    assert @enrollment_record.usable?, "Enrollment token usable"
  end

  # ─── Phase 2: Territory Enrollment ────────────────────────

  def phase_enrollment
    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: @enrollment_token,
           name: "e2e-nexus-1",
           labels: { arch: "arm64", os: "darwin" },
           metadata: { capacity: { max_directives: 3 } },
         },
         as: :json

    assert_response 201, "Enrollment returns 201"
    body = JSON.parse(response.body)
    @territory_id = body["territory_id"]
    assert @territory_id.present?, "Territory ID returned"
    assert body.dig("config", "poll_interval_seconds").present?, "Config has poll_interval"
    assert body.dig("config", "lease_ttl_seconds").present?, "Config has lease_ttl"

    @territory_record = Conduits::Territory.find(@territory_id)
    assert_equal "online", @territory_record.status, "Territory is online"
    assert_equal "e2e-nexus-1", @territory_record.name, "Territory name"

    @enrollment_record.reload
    assert @enrollment_record.used_at.present?, "Enrollment token marked as used"
    refute @enrollment_record.usable?, "Enrollment token no longer usable"

    # Enroll with CSR for mTLS
    _, enrollment_token2 = Conduits::EnrollmentToken.generate!(
      account: @account,
      user: @user,
      ttl: 1.hour,
      labels: { env: "e2e-test" }
    )

    key = OpenSSL::PKey::RSA.new(2048)
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/O=e2e-test/CN=e2e-nexus-mtls")
    csr.public_key = key.public_key
    csr.sign(key, OpenSSL::Digest::SHA256.new)

    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: enrollment_token2,
           name: "e2e-nexus-mtls",
           csr_pem: csr.to_pem,
           labels: { arch: "amd64", os: "linux" },
         },
         as: :json

    assert_response 201, "CSR enrollment returns 201"
    body2 = JSON.parse(response.body)
    assert body2["territory_id"].present?, "CSR enrollment territory_id returned"
    assert body2["mtls_client_cert_pem"].present?, "CSR enrollment returned client cert"
    assert body2["ca_bundle_pem"].present?, "CSR enrollment returned CA bundle"

    territory2 = Conduits::Territory.find(body2["territory_id"])
    assert territory2.client_cert_fingerprint.present?, "Territory fingerprint recorded"

    post "/conduits/v1/territories/heartbeat",
         params: { nexus_version: "0.1.0-e2e-mtls" },
         headers: { "X-Nexus-Client-Cert-Fingerprint" => territory2.client_cert_fingerprint },
         as: :json

    assert_response 200, "Territory heartbeat works with fingerprint header"
    territory2.reload
    assert_equal "0.1.0-e2e-mtls", territory2.nexus_version, "Territory nexus_version (mtls)"
  end

  # ─── Phase 3: Create Directive via User API ───────────────

  def phase_create_directive
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "echo 'Hello from E2E test'",
           shell: "/bin/bash",
           sandbox_profile: "untrusted",
           timeout_seconds: 60,
           requested_capabilities: { network: true },
         },
         headers: user_api_headers,
         as: :json

    assert_response 201, "Directive creation returns 201"
    body = JSON.parse(response.body)
    @directive_id = body["directive_id"]
    assert @directive_id.present?, "Directive ID returned"
    assert_equal "queued", body["state"], "Directive state is queued"

    @directive = Conduits::Directive.find(@directive_id)
    assert_equal "echo 'Hello from E2E test'", @directive.command
    assert_equal "/bin/bash", @directive.shell
    assert_equal "untrusted", @directive.sandbox_profile
  end

  # ─── Phase 4: Poll and Claim ──────────────────────────────

  def phase_poll_and_claim
    post "/conduits/v1/polls",
         params: {
           supported_sandbox_profiles: ["untrusted", "trusted"],
           max_directives_to_claim: 3,
         },
         headers: territory_headers,
         as: :json

    assert_response 200, "Poll returns 200"
    body = JSON.parse(response.body)
    assert body["directives"].is_a?(Array), "Directives array returned"
    assert_equal 1, body["directives"].length, "One directive claimed"

    claimed = body["directives"][0]
    assert_equal @directive_id, claimed["directive_id"]
    assert claimed["directive_token"].present?, "Directive token returned"
    @directive_token = claimed["directive_token"]

    spec = claimed["spec"]
    assert_equal "echo 'Hello from E2E test'", spec["command"]
    assert_equal "/bin/bash", spec["shell"]
    assert_equal "/workspace", spec.dig("facility", "mount")
    assert_equal "https://github.com/example/test-repo", spec.dig("facility", "repo_url")

    @directive.reload
    assert_equal "leased", @directive.state
    assert_equal @territory_id, @directive.territory_id
    assert @directive.lease_expires_at.present?, "Lease expires_at set"

    @facility.reload
    assert @facility.locked?, "Facility locked after claim"
    assert_equal @directive.id, @facility.locked_by_directive_id

    # Second poll returns empty
    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    body2 = JSON.parse(response.body)
    assert_equal 0, body2["directives"].length, "Second poll returns no directives"
    assert body2["retry_after_seconds"].to_i > 0, "Retry after > 0 when empty"
  end

  # ─── Phase 5: Started Report ──────────────────────────────

  def phase_started_report
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: {
           sandbox_version: "0.1.0-e2e",
           nexus_version: "0.1.0-e2e",
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Started returns 200"
    body = JSON.parse(response.body)
    assert body["ok"], "Started response ok"
    refute body["duplicate"], "Started is not duplicate"

    @directive.reload
    assert_equal "running", @directive.state
    assert_equal "0.1.0-e2e", @directive.nexus_version
    assert_equal "0.1.0-e2e", @directive.sandbox_version

    # Retry started (idempotent)
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: { sandbox_version: "0.1.0-e2e", nexus_version: "0.1.0-e2e" },
         headers: directive_headers,
         as: :json

    assert_response 200, "Started retry returns 200"
    body2 = JSON.parse(response.body)
    assert body2["ok"]
    assert body2["duplicate"], "Started retry duplicate"
    assert_equal "running", body2["state"]

    # Started retry with mismatched metadata
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: { sandbox_version: "0.1.0-e2e", nexus_version: "0.1.0-e2e-mismatch" },
         headers: directive_headers,
         as: :json

    assert_response 409, "Started retry (mismatch) returns 409"
  end

  # ─── Phase 6: Directive Heartbeat ─────────────────────────

  def phase_directive_heartbeat
    old_heartbeat = @directive.last_heartbeat_at

    post "/conduits/v1/directives/#{@directive_id}/heartbeat",
         params: {},
         headers: directive_headers,
         as: :json

    assert_response 200, "Heartbeat returns 200"
    body = JSON.parse(response.body)
    refute body["cancel_requested"], "Cancel not requested"
    assert body["lease_renewed"], "Lease renewed"
    assert body["directive_token"].present?, "Refreshed directive_token returned"

    @directive.reload
    assert(old_heartbeat.nil? || @directive.last_heartbeat_at > old_heartbeat,
           "Heartbeat timestamp updated")

    # Verify refreshed token works
    refreshed_token = body["directive_token"]
    post "/conduits/v1/directives/#{@directive_id}/heartbeat",
         params: {},
         headers: {
           "X-Nexus-Territory-Id" => @territory_id,
           "Authorization" => "Bearer #{refreshed_token}",
         },
         as: :json

    assert_response 200, "Heartbeat with refreshed token returns 200"
  end

  # ─── Phase 7: Log Chunks ─────────────────────────────────

  def phase_log_chunks
    stdout_data = "Hello from E2E test\nLine 2 of stdout\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout", seq: 0,
           bytes: Base64.strict_encode64(stdout_data),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Stdout log_chunks returns 200"

    stderr_data = "WARNING: test warning\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stderr", seq: 0,
           bytes: Base64.strict_encode64(stderr_data),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Stderr log_chunks returns 200"

    stdout_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stdout").order(:seq)
    stderr_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stderr").order(:seq)

    assert_equal 1, stdout_chunks.count
    assert_equal 1, stderr_chunks.count
    assert_equal stdout_data, stdout_chunks.pluck(:bytes).join
    assert_equal stderr_data, stderr_chunks.pluck(:bytes).join

    # Append more stdout
    more_stdout = "Line 3 appended\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout", seq: 1,
           bytes: Base64.strict_encode64(more_stdout),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Stdout append returns 200"
    stdout_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stdout").order(:seq)
    assert_equal stdout_data + more_stdout, stdout_chunks.pluck(:bytes).join

    # Read log chunks via user API (seq pagination)
    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stdout", after_seq: -1, limit: 1 },
        headers: user_api_headers,
        as: :json

    assert_response 200, "Stdout read returns 200 (page 1)"
    body = JSON.parse(response.body)
    assert_equal "stdout", body["stream"]
    assert_equal 1, body["chunks"].length
    assert_equal 0, body["chunks"][0]["seq"]
    assert_equal stdout_data, Base64.strict_decode64(body["chunks"][0]["bytes_base64"])
    assert_equal 0, body["next_after_seq"]
    refute body["stdout_truncated"]

    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stdout", after_seq: body["next_after_seq"], limit: 200 },
        headers: user_api_headers,
        as: :json

    assert_response 200, "Stdout read returns 200 (page 2)"
    body2 = JSON.parse(response.body)
    assert_equal 1, body2["chunks"].length
    assert_equal 1, body2["chunks"][0]["seq"]
    assert_equal more_stdout, Base64.strict_decode64(body2["chunks"][0]["bytes_base64"])

    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stderr", after_seq: -1, limit: 200 },
        headers: user_api_headers,
        as: :json

    assert_response 200, "Stderr read returns 200"
    body3 = JSON.parse(response.body)
    assert_equal "stderr", body3["stream"]
    assert_equal 1, body3["chunks"].length
    assert_equal stderr_data, Base64.strict_decode64(body3["chunks"][0]["bytes_base64"])
  end

  # ─── Phase 8: Finished Report ─────────────────────────────

  def phase_finished_report
    diff_content = <<~DIFF
      --- a/file.txt
      +++ b/file.txt
      @@ -1,3 +1,3 @@
       line 1
      -old line 2
      +new line 2
       line 3
    DIFF

    post "/conduits/v1/directives/#{@directive_id}/finished",
         params: {
           status: "succeeded",
           exit_code: 0,
           stdout_truncated: false,
           stderr_truncated: false,
           diff_truncated: false,
           snapshot_before: "abc123",
           snapshot_after: "def456",
           artifacts_manifest: { files: ["output.tar.gz"] },
           diff_base64: Base64.strict_encode64(diff_content),
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Finished returns 200"
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "succeeded", body["final_state"]
    refute body["duplicate"]

    @directive.reload
    assert_equal "succeeded", @directive.state
    assert_equal 0, @directive.exit_code
    assert_equal "succeeded", @directive.finished_status
    assert_equal "abc123", @directive.snapshot_before
    assert_equal "def456", @directive.snapshot_after
    assert @directive.diff_blob.attached?, "Diff blob attached"
    assert_equal diff_content, @directive.diff_blob.download

    @facility.reload
    refute @facility.locked?, "Facility unlocked after finish"

    # Retry finished (idempotent)
    post "/conduits/v1/directives/#{@directive_id}/finished",
         params: {
           status: "succeeded", exit_code: 0,
           stdout_truncated: false, stderr_truncated: false, diff_truncated: false,
           snapshot_before: "abc123", snapshot_after: "def456",
           artifacts_manifest: { files: ["output.tar.gz"] },
           diff_base64: Base64.strict_encode64(diff_content),
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Finished retry returns 200"
    body2 = JSON.parse(response.body)
    assert body2["ok"]
    assert body2["duplicate"]

    # Started retry after finished (network reordering)
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: { sandbox_version: "0.1.0-e2e", nexus_version: "0.1.0-e2e" },
         headers: directive_headers,
         as: :json

    assert_response 200, "Started after finish returns 200"
    body3 = JSON.parse(response.body)
    assert body3["duplicate"]
    assert_equal "succeeded", body3["state"]

    # Late log_chunks after finished
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout", seq: 2,
           bytes: Base64.strict_encode64("late stdout\n"),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_response 200, "Late log_chunks returns 200"
    body4 = JSON.parse(response.body)
    assert body4["ok"]
    assert body4["stored"]
    refute body4["duplicate"]

    # Finished retry with mismatched payload
    post "/conduits/v1/directives/#{@directive_id}/finished",
         params: { status: "succeeded", exit_code: 1 },
         headers: directive_headers,
         as: :json

    assert_response 409, "Finished retry (mismatch) returns 409"
  end

  # ─── Phase 9: Query Directive Result ──────────────────────

  def phase_query_directive
    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}",
        headers: user_api_headers

    assert_response 200, "Show directive returns 200"
    body = JSON.parse(response.body)
    assert_equal "succeeded", body["state"]
    assert_equal 0, body["exit_code"]
    assert_equal "echo 'Hello from E2E test'", body["command"]

    get "/mothership/api/v1/facilities/#{@facility.id}/directives",
        headers: user_api_headers

    assert_response 200, "Index returns 200"
    body = JSON.parse(response.body)
    assert body["directives"].is_a?(Array)
    assert body["directives"].length >= 1
  end

  # ─── Phase 10: Second Directive Cycle ─────────────────────

  def phase_second_directive_cycle
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "ls -la /workspace",
           sandbox_profile: "untrusted",
           timeout_seconds: 30,
         },
         headers: user_api_headers,
         as: :json

    assert_response 201, "Second directive created"
    body = JSON.parse(response.body)
    directive2_id = body["directive_id"]

    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    body = JSON.parse(response.body)
    assert_equal 1, body["directives"].length
    directive2_token = body["directives"][0]["directive_token"]

    @facility.reload
    assert @facility.locked?, "Facility re-locked for second directive"
    assert_equal directive2_id, @facility.locked_by_directive_id

    post "/conduits/v1/directives/#{directive2_id}/started",
         params: { nexus_version: "0.1.0-e2e" },
         headers: directive_headers_for(directive2_token),
         as: :json

    assert_response 200, "Second directive started"

    post "/conduits/v1/directives/#{directive2_id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(directive2_token),
         as: :json

    assert_response 200, "Second directive finished (failed)"
    body = JSON.parse(response.body)
    assert_equal "failed", body["final_state"]

    @facility.reload
    refute @facility.locked?, "Facility unlocked after second directive"
  end

  # ─── Phase 10.5: Lease Expiry Reaper ─────────────────────

  def phase_lease_expiry_reaper
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "echo lease-expiry",
           sandbox_profile: "untrusted",
           timeout_seconds: 30,
         },
         headers: user_api_headers,
         as: :json

    assert_response 201, "Lease-expiry directive created"
    directive_id = JSON.parse(response.body)["directive_id"]

    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    assert_response 200
    claimed = JSON.parse(response.body)["directives"][0]
    assert_equal directive_id, claimed["directive_id"]

    directive = Conduits::Directive.find(directive_id)
    directive.update!(lease_expires_at: 1.minute.ago)

    Conduits::LeaseReaperService.new.call(limit: 10)

    directive.reload
    @facility.reload

    assert_equal "queued", directive.state, "Directive returned to queued"
    refute @facility.locked?, "Facility unlocked after lease expiry"
  end

  # ─── Phase 11: Territory Heartbeat ────────────────────────

  def phase_territory_heartbeat
    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.1.0-e2e",
           labels: { arch: "arm64" },
           capacity: { max_directives: 5 },
         },
         headers: territory_headers,
         as: :json

    assert_response 200, "Territory heartbeat returns 200"
    body = JSON.parse(response.body)
    assert body["ok"]

    @territory_record.reload
    assert @territory_record.last_heartbeat_at.present?
    assert_equal "0.1.0-e2e", @territory_record.nexus_version
  end

  # ─── Phase 12: Edge Cases ─────────────────────────────────

  def phase_edge_cases
    # Invalid enrollment token
    post "/conduits/v1/territories/enroll",
         params: { enroll_token: "invalid-token" },
         as: :json

    assert_response 422, "Invalid enrollment token returns 422"

    # Reused enrollment token
    post "/conduits/v1/territories/enroll",
         params: { enroll_token: @enrollment_token },
         as: :json

    assert_response 422, "Reused enrollment token returns 422"

    # Enrollment rate limiting (10/hour)
    6.times do |i|
      post "/conduits/v1/territories/enroll",
           params: { enroll_token: "invalid-token-rate-limit-#{i}" },
           as: :json

      assert_response 422, "Rate limit warm-up enroll #{i + 1}/6 returns 422"
    end

    post "/conduits/v1/territories/enroll",
         params: { enroll_token: "invalid-token-rate-limited" },
         as: :json

    assert_response 429, "Enrollment rate limit returns 429"
    assert response.headers["Retry-After"].present?, "Retry-After header present"
    body = JSON.parse(response.body)
    assert_equal "rate_limited", body["error"]

    # Missing territory header
    post "/conduits/v1/polls", params: {}, as: :json
    assert_response 401, "Missing territory header returns 401"

    # Unknown territory
    post "/conduits/v1/polls",
         params: {},
         headers: { "X-Nexus-Territory-Id" => "00000000-0000-0000-0000-000000000000" },
         as: :json

    assert_response 401, "Unknown territory returns 401"

    # Invalid sandbox profile
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: { command: "echo bad", sandbox_profile: "super_admin_mode" },
         headers: user_api_headers,
         as: :json

    assert_response 422, "Invalid sandbox profile returns 422"

    # Invalid stream in log_chunks
    d3 = Conduits::Directive.create!(
      account: @account, facility: @facility,
      requested_by_user: @user,
      command: "echo edge_case",
      sandbox_profile: "untrusted"
    )
    d3.territory = @territory_record
    d3.lease_expires_at = 5.minutes.from_now
    d3.lease!
    d3.start!
    token3 = Conduits::DirectiveToken.encode(
      directive_id: d3.id, territory_id: @territory_record.id, ttl: 300
    )

    post "/conduits/v1/directives/#{d3.id}/log_chunks",
         params: { stream: "invalid_stream", seq: 0, bytes: "dGVzdA==" },
         headers: directive_headers_for(token3),
         as: :json

    assert_response 422, "Invalid stream returns 422"

    # log_chunks should treat truncated="false" (string) as false
    post "/conduits/v1/directives/#{d3.id}/log_chunks",
         params: { stream: "stdout", seq: 0, bytes: Base64.strict_encode64("ok\n"), truncated: "false" },
         headers: directive_headers_for(token3),
         as: :json

    assert_response 200, "truncated=\"false\" string is accepted"
    body_ok = JSON.parse(response.body)
    refute body_ok["truncated"], "Chunk is not marked truncated"
    d3.reload
    refute d3.stdout_truncated, "Directive stdout_truncated remains false"

    # Reject oversized log_chunks bytes (DoS hardening)
    too_big = "a" * (256.kilobytes + 1)
    post "/conduits/v1/directives/#{d3.id}/log_chunks",
         params: { stream: "stdout", seq: 1, bytes: Base64.strict_encode64(too_big) },
         headers: directive_headers_for(token3),
         as: :json

    assert_response 422, "Oversize log chunk returns 422"

    # Reject directive token territory_id mismatch (must match current territory)
    bad_token = Conduits::DirectiveToken.encode(
      directive_id: d3.id,
      territory_id: "00000000-0000-0000-0000-000000000000",
      ttl: 300
    )
    post "/conduits/v1/directives/#{d3.id}/heartbeat",
         params: {},
         headers: directive_headers_for(bad_token),
         as: :json

    assert_response 403, "Directive token territory mismatch returns 403"

    # Reject valid directive token when current territory identity is different.
    # This ensures a stolen token cannot be replayed by another territory.
    other_territory = Conduits::Territory.create!(account: @account, name: "other-territory")

    d6 = Conduits::Directive.create!(
      account: @account, facility: @facility,
      requested_by_user: @user,
      command: "echo edge_case_token_replay",
      sandbox_profile: "untrusted"
    )
    d6.territory = @territory_record
    d6.lease_expires_at = 5.minutes.from_now
    d6.lease!
    token6 = Conduits::DirectiveToken.encode(
      directive_id: d6.id, territory_id: @territory_record.id, ttl: 300
    )
    other_headers = { "X-Nexus-Territory-Id" => other_territory.id, "Authorization" => "Bearer #{token6}" }

    post "/conduits/v1/directives/#{d6.id}/started",
         params: { sandbox_version: "0.1.0-e2e", nexus_version: "0.1.0-e2e" },
         headers: other_headers,
         as: :json
    assert_response 403, "Started with wrong territory identity returns 403"
    d6.reload
    assert d6.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d6.id}/heartbeat",
         params: {},
         headers: other_headers,
         as: :json
    assert_response 403, "Heartbeat with wrong territory identity returns 403"
    d6.reload
    assert d6.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d6.id}/log_chunks",
         params: { stream: "stdout", seq: 0, bytes: Base64.strict_encode64("x\n") },
         headers: other_headers,
         as: :json
    assert_response 403, "log_chunks with wrong territory identity returns 403"
    d6.reload
    assert d6.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d6.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: other_headers,
         as: :json
    assert_response 403, "Finished with wrong territory identity returns 403"
    d6.reload
    assert d6.leased?, "Directive state is unchanged"

    # Reject directive token when directive is bound to another territory.
    # This exercises the final territory binding check in authenticate_directive!.
    d7 = Conduits::Directive.create!(
      account: @account, facility: @facility,
      requested_by_user: @user,
      command: "echo edge_case_territory_mismatch",
      sandbox_profile: "untrusted"
    )
    d7.territory = other_territory
    d7.lease_expires_at = 5.minutes.from_now
    d7.lease!
    token7 = Conduits::DirectiveToken.encode(
      directive_id: d7.id, territory_id: @territory_record.id, ttl: 300
    )

    post "/conduits/v1/directives/#{d7.id}/started",
         params: { sandbox_version: "0.1.0-e2e", nexus_version: "0.1.0-e2e" },
         headers: directive_headers_for(token7),
         as: :json
    assert_response 403, "Started with directive territory mismatch returns 403"
    d7.reload
    assert d7.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d7.id}/heartbeat",
         params: {},
         headers: directive_headers_for(token7),
         as: :json
    assert_response 403, "Heartbeat with directive territory mismatch returns 403"
    d7.reload
    assert d7.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d7.id}/log_chunks",
         params: { stream: "stdout", seq: 0, bytes: Base64.strict_encode64("x\n") },
         headers: directive_headers_for(token7),
         as: :json
    assert_response 403, "log_chunks with directive territory mismatch returns 403"
    d7.reload
    assert d7.leased?, "Directive state is unchanged"

    post "/conduits/v1/directives/#{d7.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token7),
         as: :json
    assert_response 403, "Finished with directive territory mismatch returns 403"
    d7.reload
    assert d7.leased?, "Directive state is unchanged"

    # Invalid finished status
    post "/conduits/v1/directives/#{d3.id}/finished",
         params: { status: "exploded", exit_code: 42 },
         headers: directive_headers_for(token3),
         as: :json

    assert_response 422, "Invalid finished status returns 422"

    # Invalid diff_base64
    post "/conduits/v1/directives/#{d3.id}/finished",
         params: { status: "failed", exit_code: 1, diff_base64: "not base64" },
         headers: directive_headers_for(token3),
         as: :json

    assert_response 422, "Invalid diff_base64 returns 422"

    # diff_base64 too large
    d5 = Conduits::Directive.create!(
      account: @account, facility: @facility,
      requested_by_user: @user,
      command: "echo edge_case_diff_too_large",
      sandbox_profile: "untrusted",
      limits: { max_diff_bytes: 4 }
    )
    d5.territory = @territory_record
    d5.lease_expires_at = 5.minutes.from_now
    d5.lease!
    d5.start!
    token5 = Conduits::DirectiveToken.encode(
      directive_id: d5.id, territory_id: @territory_record.id, ttl: 300
    )

    post "/conduits/v1/directives/#{d5.id}/finished",
         params: { status: "failed", exit_code: 1, diff_base64: Base64.strict_encode64("12345") },
         headers: directive_headers_for(token5),
         as: :json

    assert_response 422, "Oversize diff_base64 returns 422"

    post "/conduits/v1/directives/#{d5.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token5),
         as: :json

    assert_response 200, "Finish after oversize diff rejection returns 200"

    # Finished without started (leased -> implicit start)
    d4 = Conduits::Directive.create!(
      account: @account, facility: @facility,
      requested_by_user: @user,
      command: "echo edge_case_finish_without_started",
      sandbox_profile: "untrusted"
    )
    d4.territory = @territory_record
    d4.lease_expires_at = 5.minutes.from_now
    d4.lease!
    token4 = Conduits::DirectiveToken.encode(
      directive_id: d4.id, territory_id: @territory_record.id, ttl: 300
    )

    post "/conduits/v1/directives/#{d4.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token4),
         as: :json

    assert_response 200, "Finished without started returns 200"
    body4 = JSON.parse(response.body)
    assert body4["ok"]
    refute body4["duplicate"]
    assert_equal "failed", body4["final_state"]

    # Retry
    post "/conduits/v1/directives/#{d4.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token4),
         as: :json

    assert_response 200, "Finished without started retry returns 200"
    body5 = JSON.parse(response.body)
    assert body5["ok"]
    assert body5["duplicate"]

    # Clean up edge-case directives
    d3.succeed!
    d3.facility.unlock! if d3.facility.locked?
  end

  # ─── Helpers ──────────────────────────────────────────────

  def territory_headers
    { "X-Nexus-Territory-Id" => @territory_id }
  end

  def directive_headers
    {
      "X-Nexus-Territory-Id" => @territory_id,
      "Authorization" => "Bearer #{@directive_token}",
    }
  end

  def directive_headers_for(token)
    {
      "X-Nexus-Territory-Id" => @territory_id,
      "Authorization" => "Bearer #{token}",
    }
  end

  def user_api_headers
    {
      "X-Account-Id" => @account.id,
      "X-User-Id" => @user.id,
    }
  end
end
