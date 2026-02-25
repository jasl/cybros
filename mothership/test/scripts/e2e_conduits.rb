#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end test script for the Conduits subsystem.
#
# Exercises the full loop:
#   1. Seed data (Account, User, Facility, EnrollmentToken)
#   2. Territory enrollment via enroll API
#   3. User creates a directive via Mothership API
#   4. Territory polls and claims the directive
#   5. Nexus reports started
#   6. Nexus sends heartbeat
#   7. Nexus sends log chunks (stdout + stderr)
#   8. Nexus reports finished (with diff blob)
#   9. User queries directive status via Mothership API
#
# Usage:
#   bin/rails runner test/scripts/e2e_conduits.rb
#
# This script uses the Rails integration test helpers to simulate
# HTTP requests without needing a running server.

require "action_dispatch/testing/integration"
require "openssl"

class ConduitsE2ETest
  include ActionDispatch::Integration::Runner
  include ActionDispatch::IntegrationTest::Behavior

  attr_reader :passed_count, :failed_count, :errors

  def initialize
    @app = Rails.application
    @passed_count = 0
    @failed_count = 0
    @errors = []
    reset!
  end

  def run_all
    puts "=" * 60
    puts "  Conduits E2E Test Suite"
    puts "=" * 60
    puts ""

    # Phase 1: Seed data
    seed_data

    # Phase 2: Enrollment
    test_enrollment

    # Phase 3: User creates directive
    test_create_directive

    # Phase 4: Poll and claim
    test_poll_and_claim

    # Phase 5: Started report
    test_started_report

    # Phase 6: Heartbeat
    test_directive_heartbeat

    # Phase 7: Log chunks
    test_log_chunks

    # Phase 8: Finished report
    test_finished_report

    # Phase 9: User queries result
    test_query_directive

    # Phase 10: Second directive — test facility unlock + re-lock cycle
    test_second_directive_cycle

    # Phase 10.5: Lease expiry reaper
    test_lease_expiry_reaper

    # Phase 11: Territory heartbeat
    test_territory_heartbeat

    # Phase 12: Edge cases
    test_edge_cases

    # Summary
    print_summary
  end

  private

  # ─── Seed Data ─────────────────────────────────────────────

  def seed_data
    section("Phase 1: Seed Data")

    @account = Account.create!(name: "e2e-test-account")
    @user = User.create!(account: @account, name: "e2e-test-user")
    @territory_record = nil # will be created via enroll
    @facility = Conduits::Facility.create!(
      account: @account,
      owner: @user,
      territory: Conduits::Territory.create!(account: @account, name: "seed-territory"),
      kind: "repo",
      retention_policy: "keep_last_5",
      repo_url: "https://github.com/example/test-repo"
    )

    # Generate enrollment token
    @enrollment_record, @enrollment_token = Conduits::EnrollmentToken.generate!(
      account: @account,
      user: @user,
      ttl: 1.hour,
      labels: { env: "e2e-test" }
    )

    assert_true("Account created", @account.persisted?)
    assert_true("User created", @user.persisted?)
    assert_true("Facility created", @facility.persisted?)
    assert_true("Enrollment token created", @enrollment_record.persisted?)
    assert_true("Enrollment token usable", @enrollment_record.usable?)
    puts ""
  end

  # ─── Phase 2: Territory Enrollment ────────────────────────

  def test_enrollment
    section("Phase 2: Territory Enrollment")

    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: @enrollment_token,
           name: "e2e-nexus-1",
           labels: { arch: "arm64", os: "darwin" },
           metadata: { capacity: { max_directives: 3 } },
         },
         as: :json

    assert_status(201, "Enrollment returns 201")
    body = JSON.parse(response.body)
    @territory_id = body["territory_id"]
    assert_true("Territory ID returned", @territory_id.present?)
    assert_true("Config returned with poll_interval",
                body.dig("config", "poll_interval_seconds").present?)
    assert_true("Config returned with lease_ttl",
                body.dig("config", "lease_ttl_seconds").present?)

    # Verify territory state
    @territory_record = Conduits::Territory.find(@territory_id)
    assert_equal("Territory is online", "online", @territory_record.status)
    assert_equal("Territory name", "e2e-nexus-1", @territory_record.name)

    # Verify enrollment token is now used
    @enrollment_record.reload
    assert_true("Enrollment token marked as used", @enrollment_record.used_at.present?)
    assert_false("Enrollment token no longer usable", @enrollment_record.usable?)

    # Optional: enroll with CSR to issue an mTLS client certificate (Phase 1+ behavior)
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

    assert_status(201, "Enrollment (CSR) returns 201")
    body2 = JSON.parse(response.body)
    territory2_id = body2["territory_id"]
    assert_true("CSR enrollment territory_id returned", territory2_id.present?)
    assert_true("CSR enrollment returned client cert", body2["mtls_client_cert_pem"].present?)
    assert_true("CSR enrollment returned CA bundle", body2["ca_bundle_pem"].present?)

    territory2 = Conduits::Territory.find(territory2_id)
    assert_true("Territory fingerprint recorded", territory2.client_cert_fingerprint.present?)

    post "/conduits/v1/territories/heartbeat",
         params: { nexus_version: "0.1.0-e2e-mtls" },
         headers: { "X-Nexus-Client-Cert-Fingerprint" => territory2.client_cert_fingerprint },
         as: :json

    assert_status(200, "Territory heartbeat works with fingerprint header")

    territory2.reload
    assert_equal("Territory nexus_version recorded (mtls)", "0.1.0-e2e-mtls", territory2.nexus_version)

    puts ""
  end

  # ─── Phase 3: Create Directive via User API ───────────────

  def test_create_directive
    section("Phase 3: Create Directive (User API)")

    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "echo 'Hello from E2E test'",
           shell: "/bin/bash",
           sandbox_profile: "untrusted",
           timeout_seconds: 60,
           requested_capabilities: { network: true },
         },
         headers: { "X-User-Id" => @user.id },
         as: :json

    assert_status(201, "Directive creation returns 201")
    body = JSON.parse(response.body)
    @directive_id = body["directive_id"]
    assert_true("Directive ID returned", @directive_id.present?)
    assert_equal("Directive state is queued", "queued", body["state"])

    @directive = Conduits::Directive.find(@directive_id)
    assert_equal("Command stored correctly", "echo 'Hello from E2E test'", @directive.command)
    assert_equal("Shell stored correctly", "/bin/bash", @directive.shell)
    assert_equal("Sandbox profile stored", "untrusted", @directive.sandbox_profile)

    puts ""
  end

  # ─── Phase 4: Poll and Claim ──────────────────────────────

  def test_poll_and_claim
    section("Phase 4: Poll and Claim Directive")

    post "/conduits/v1/polls",
         params: {
           supported_sandbox_profiles: ["untrusted", "trusted"],
           max_directives_to_claim: 3,
         },
         headers: territory_headers,
         as: :json

    assert_status(200, "Poll returns 200")
    body = JSON.parse(response.body)
    assert_true("Directives array returned", body["directives"].is_a?(Array))
    assert_equal("One directive claimed", 1, body["directives"].length)

    claimed = body["directives"][0]
    assert_equal("Claimed directive matches", @directive_id, claimed["directive_id"])
    assert_true("Directive token returned", claimed["directive_token"].present?)
    @directive_token = claimed["directive_token"]

    # Verify spec
    spec = claimed["spec"]
    assert_equal("Spec has correct command", "echo 'Hello from E2E test'", spec["command"])
    assert_equal("Spec has correct shell", "/bin/bash", spec["shell"])
    assert_equal("Spec has facility mount", "/workspace", spec.dig("facility", "mount"))
    assert_equal("Spec has repo_url", "https://github.com/example/test-repo",
                 spec.dig("facility", "repo_url"))

    # Verify directive state changed to leased
    @directive.reload
    assert_equal("Directive state is leased", "leased", @directive.state)
    assert_equal("Directive territory assigned", @territory_id, @directive.territory_id)
    assert_true("Lease expires_at set", @directive.lease_expires_at.present?)

    # Verify facility is locked
    @facility.reload
    assert_true("Facility locked after claim", @facility.locked?)
    assert_equal("Facility locked by directive", @directive.id, @facility.locked_by_directive_id)

    # Second poll should return empty (no more queued directives)
    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    body2 = JSON.parse(response.body)
    assert_equal("Second poll returns no directives", 0, body2["directives"].length)
    assert_true("Retry after > 0 when empty", body2["retry_after_seconds"].to_i > 0)

    puts ""
  end

  # ─── Phase 5: Started Report ──────────────────────────────

  def test_started_report
    section("Phase 5: Nexus Reports Started")

    post "/conduits/v1/directives/#{@directive_id}/started",
         params: {
           sandbox_version: "0.1.0-e2e",
           nexus_version: "0.1.0-e2e",
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Started returns 200")
    body = JSON.parse(response.body)
    assert_true("Started response ok", body["ok"])
    assert_false("Started is not duplicate", body["duplicate"])

    @directive.reload
    assert_equal("Directive state is running", "running", @directive.state)
    assert_equal("Nexus version recorded", "0.1.0-e2e", @directive.nexus_version)
    assert_equal("Sandbox version recorded", "0.1.0-e2e", @directive.sandbox_version)

    # Retry started (idempotent)
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: {
           sandbox_version: "0.1.0-e2e",
           nexus_version: "0.1.0-e2e",
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Started retry returns 200")
    body2 = JSON.parse(response.body)
    assert_true("Started retry ok", body2["ok"])
    assert_true("Started retry duplicate", body2["duplicate"])
    assert_equal("Started retry state is running", "running", body2["state"])

    # started retry with mismatched metadata should be rejected
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: {
           sandbox_version: "0.1.0-e2e",
           nexus_version: "0.1.0-e2e-mismatch",
         },
         headers: directive_headers,
         as: :json

    assert_status(409, "Started retry (mismatch) returns 409")

    puts ""
  end

  # ─── Phase 6: Directive Heartbeat ─────────────────────────

  def test_directive_heartbeat
    section("Phase 6: Directive Heartbeat")

    old_heartbeat = @directive.last_heartbeat_at

    post "/conduits/v1/directives/#{@directive_id}/heartbeat",
         params: {},
         headers: directive_headers,
         as: :json

    assert_status(200, "Heartbeat returns 200")
    body = JSON.parse(response.body)
    assert_false("Cancel not requested", body["cancel_requested"])
    assert_true("Lease renewed", body["lease_renewed"])

    @directive.reload
    assert_true("Heartbeat timestamp updated",
                old_heartbeat.nil? || @directive.last_heartbeat_at > old_heartbeat)

    puts ""
  end

  # ─── Phase 7: Log Chunks ─────────────────────────────────

  def test_log_chunks
    section("Phase 7: Log Chunks Upload")

    # Send stdout chunk
    stdout_data = "Hello from E2E test\nLine 2 of stdout\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout",
           seq: 0,
           bytes: Base64.strict_encode64(stdout_data),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Stdout log_chunks returns 200")

    # Send stderr chunk
    stderr_data = "WARNING: test warning\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stderr",
           seq: 0,
           bytes: Base64.strict_encode64(stderr_data),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Stderr log_chunks returns 200")

    # Verify log chunks stored
    stdout_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stdout").order(:seq)
    stderr_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stderr").order(:seq)

    assert_equal("Stdout chunk count", 1, stdout_chunks.count)
    assert_equal("Stderr chunk count", 1, stderr_chunks.count)

    assert_equal("Stdout content matches", stdout_data, stdout_chunks.pluck(:bytes).join)
    assert_equal("Stderr content matches", stderr_data, stderr_chunks.pluck(:bytes).join)

    # Append more stdout data
    more_stdout = "Line 3 appended\n"
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout",
           seq: 1,
           bytes: Base64.strict_encode64(more_stdout),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Stdout append returns 200")
    stdout_chunks = Conduits::LogChunk.where(directive_id: @directive_id, stream: "stdout").order(:seq)
    assert_equal("Stdout content appended correctly", stdout_data + more_stdout, stdout_chunks.pluck(:bytes).join)

    # Read log chunks via user API (seq pagination)
    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stdout", after_seq: -1, limit: 1 },
        headers: { "X-User-Id" => @user.id },
        as: :json

    assert_status(200, "Stdout log_chunks read returns 200 (page 1)")
    body = JSON.parse(response.body)
    assert_equal("Stdout read stream", "stdout", body["stream"])
    assert_equal("Stdout read chunk count page 1", 1, body["chunks"].length)
    assert_equal("Stdout read seq page 1", 0, body["chunks"][0]["seq"])
    assert_equal("Stdout read content page 1", stdout_data, Base64.strict_decode64(body["chunks"][0]["bytes_base64"]))
    assert_equal("Stdout read next_after_seq page 1", 0, body["next_after_seq"])
    assert_false("Stdout truncated flag", body["stdout_truncated"])

    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stdout", after_seq: body["next_after_seq"], limit: 200 },
        headers: { "X-User-Id" => @user.id },
        as: :json

    assert_status(200, "Stdout log_chunks read returns 200 (page 2)")
    body2 = JSON.parse(response.body)
    assert_equal("Stdout read chunk count page 2", 1, body2["chunks"].length)
    assert_equal("Stdout read seq page 2", 1, body2["chunks"][0]["seq"])
    assert_equal("Stdout read content page 2", more_stdout, Base64.strict_decode64(body2["chunks"][0]["bytes_base64"]))
    assert_equal("Stdout read next_after_seq page 2", 1, body2["next_after_seq"])

    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}/log_chunks",
        params: { stream: "stderr", after_seq: -1, limit: 200 },
        headers: { "X-User-Id" => @user.id },
        as: :json

    assert_status(200, "Stderr log_chunks read returns 200")
    body3 = JSON.parse(response.body)
    assert_equal("Stderr read stream", "stderr", body3["stream"])
    assert_equal("Stderr read chunk count", 1, body3["chunks"].length)
    assert_equal("Stderr read seq", 0, body3["chunks"][0]["seq"])
    assert_equal("Stderr read content", stderr_data, Base64.strict_decode64(body3["chunks"][0]["bytes_base64"]))
    assert_false("Stderr truncated flag", body3["stderr_truncated"])

    puts ""
  end

  # ─── Phase 8: Finished Report ─────────────────────────────

  def test_finished_report
    section("Phase 8: Nexus Reports Finished")

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

    assert_status(200, "Finished returns 200")
    body = JSON.parse(response.body)
    assert_true("Finished response ok", body["ok"])
    assert_equal("Final state is succeeded", "succeeded", body["final_state"])
    assert_false("Finished is not duplicate", body["duplicate"])

    @directive.reload
    assert_equal("Directive state is succeeded", "succeeded", @directive.state)
    assert_equal("Exit code recorded", 0, @directive.exit_code)
    assert_equal("Finished status recorded", "succeeded", @directive.finished_status)
    assert_equal("Snapshot before recorded", "abc123", @directive.snapshot_before)
    assert_equal("Snapshot after recorded", "def456", @directive.snapshot_after)

    # Verify diff blob
    assert_true("Diff blob attached", @directive.diff_blob.attached?)
    assert_equal("Diff content matches", diff_content, @directive.diff_blob.download)

    # Verify facility unlocked
    @facility.reload
    assert_false("Facility unlocked after finish", @facility.locked?)

    # Retry finished (idempotent)
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

    assert_status(200, "Finished retry returns 200")
    body2 = JSON.parse(response.body)
    assert_true("Finished retry ok", body2["ok"])
    assert_true("Finished retry duplicate", body2["duplicate"])
    assert_equal("Finished retry final_state", "succeeded", body2["final_state"])

    # started retry may arrive after finished due to network reordering; should be idempotent
    post "/conduits/v1/directives/#{@directive_id}/started",
         params: {
           sandbox_version: "0.1.0-e2e",
           nexus_version: "0.1.0-e2e",
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Started after finish returns 200")
    body3 = JSON.parse(response.body)
    assert_true("Started after finish duplicate", body3["duplicate"])
    assert_equal("Started after finish state", "succeeded", body3["state"])

    # log_chunks may arrive after finished due to buffering/network reordering; should be accepted (idempotent + capped)
    post "/conduits/v1/directives/#{@directive_id}/log_chunks",
         params: {
           stream: "stdout",
           seq: 2,
           bytes: Base64.strict_encode64("late stdout\n"),
           truncated: false,
         },
         headers: directive_headers,
         as: :json

    assert_status(200, "Late log_chunks returns 200")
    body4 = JSON.parse(response.body)
    assert_true("Late log_chunks ok", body4["ok"])
    assert_true("Late log_chunks stored", body4["stored"])
    assert_false("Late log_chunks not duplicate", body4["duplicate"])

    # finished retry with mismatched payload should be rejected
    post "/conduits/v1/directives/#{@directive_id}/finished",
         params: {
           status: "succeeded",
           exit_code: 1,
         },
         headers: directive_headers,
         as: :json

    assert_status(409, "Finished retry (mismatch) returns 409")

    puts ""
  end

  # ─── Phase 9: Query Directive Result ──────────────────────

  def test_query_directive
    section("Phase 9: Query Directive (User API)")

    get "/mothership/api/v1/facilities/#{@facility.id}/directives/#{@directive_id}",
        headers: { "X-User-Id" => @user.id }

    assert_status(200, "Show directive returns 200")
    body = JSON.parse(response.body)
    assert_equal("State is succeeded", "succeeded", body["state"])
    assert_equal("Exit code is 0", 0, body["exit_code"])
    assert_equal("Finished status is succeeded", "succeeded", body["finished_status"])
    assert_equal("Command matches", "echo 'Hello from E2E test'", body["command"])

    # Test index
    get "/mothership/api/v1/facilities/#{@facility.id}/directives",
        headers: { "X-User-Id" => @user.id }

    assert_status(200, "Index returns 200")
    body = JSON.parse(response.body)
    assert_true("Directives array present", body["directives"].is_a?(Array))
    assert_true("At least one directive", body["directives"].length >= 1)

    puts ""
  end

  # ─── Phase 10: Second Directive Cycle ─────────────────────

  def test_second_directive_cycle
    section("Phase 10: Second Directive Cycle (facility unlock + re-lock)")

    # Create another directive
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "ls -la /workspace",
           sandbox_profile: "untrusted",
           timeout_seconds: 30,
         },
         headers: { "X-User-Id" => @user.id },
         as: :json

    assert_status(201, "Second directive created")
    body = JSON.parse(response.body)
    directive2_id = body["directive_id"]

    # Poll to claim
    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    body = JSON.parse(response.body)
    assert_equal("Second directive claimed", 1, body["directives"].length)
    directive2_token = body["directives"][0]["directive_token"]

    # Verify facility re-locked
    @facility.reload
    assert_true("Facility re-locked for second directive", @facility.locked?)
    assert_equal("Locked by second directive", directive2_id, @facility.locked_by_directive_id)

    # Start and immediately fail
    post "/conduits/v1/directives/#{directive2_id}/started",
         params: { nexus_version: "0.1.0-e2e" },
         headers: directive_headers_for(directive2_token),
         as: :json

    assert_status(200, "Second directive started")

    post "/conduits/v1/directives/#{directive2_id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(directive2_token),
         as: :json

    assert_status(200, "Second directive finished (failed)")
    body = JSON.parse(response.body)
    assert_equal("Final state is failed", "failed", body["final_state"])

    # Facility unlocked again
    @facility.reload
    assert_false("Facility unlocked after second directive", @facility.locked?)

    puts ""
  end

  # ─── Phase 10.5: Lease Expiry Reaper ─────────────────────

  def test_lease_expiry_reaper
    section("Phase 10.5: Lease Expiry Reaper (leased -> queued + unlock)")

    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "echo lease-expiry",
           sandbox_profile: "untrusted",
           timeout_seconds: 30,
         },
         headers: { "X-User-Id" => @user.id },
         as: :json

    assert_status(201, "Lease-expiry directive created")
    directive_id = JSON.parse(response.body)["directive_id"]

    # Claim the directive so it becomes leased and locks the facility.
    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: territory_headers,
         as: :json

    assert_status(200, "Poll returns 200 for lease-expiry directive")
    claimed = JSON.parse(response.body)["directives"][0]
    assert_equal("Lease-expiry directive claimed", directive_id, claimed["directive_id"])

    # Force the lease to be expired and run the reaper.
    directive = Conduits::Directive.find(directive_id)
    directive.update!(lease_expires_at: 1.minute.ago)

    Conduits::LeaseReaperService.new.call(limit: 10)

    directive.reload
    @facility.reload

    assert_equal("Directive returned to queued", "queued", directive.state)
    assert_false("Facility unlocked after lease expiry", @facility.locked?)

    puts ""
  end

  # ─── Phase 11: Territory Heartbeat ────────────────────────

  def test_territory_heartbeat
    section("Phase 11: Territory Heartbeat")

    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.1.0-e2e",
           labels: { arch: "arm64" },
           capacity: { max_directives: 5 },
         },
         headers: territory_headers,
         as: :json

    assert_status(200, "Territory heartbeat returns 200")
    body = JSON.parse(response.body)
    assert_true("Heartbeat ok", body["ok"])

    @territory_record.reload
    assert_true("Territory heartbeat recorded", @territory_record.last_heartbeat_at.present?)
    assert_equal("Territory nexus_version recorded", "0.1.0-e2e", @territory_record.nexus_version)

    puts ""
  end

  # ─── Phase 12: Edge Cases ─────────────────────────────────

  def test_edge_cases
    section("Phase 12: Edge Cases")

    # Invalid enrollment token
    post "/conduits/v1/territories/enroll",
         params: { enroll_token: "invalid-token" },
         as: :json

    assert_status(422, "Invalid enrollment token returns 422")

    # Reused enrollment token
    post "/conduits/v1/territories/enroll",
         params: { enroll_token: @enrollment_token },
         as: :json

    assert_status(422, "Reused enrollment token returns 422")

    # Enrollment rate limiting (per-IP, Rack::Attack): 10/hour
    # Note: this suite already called enroll 4 times (2 success + 2 edge cases above),
    # so we should hit 429 on the 7th additional attempt (total 11).
    6.times do |i|
      post "/conduits/v1/territories/enroll",
           params: { enroll_token: "invalid-token-rate-limit-#{i}" },
           as: :json

      assert_status(422, "Rate limit warm-up enroll #{i + 1}/6 returns 422")
    end

    post "/conduits/v1/territories/enroll",
         params: { enroll_token: "invalid-token-rate-limited" },
         as: :json

    assert_status(429, "Enrollment rate limit returns 429")
    assert_true("Retry-After header present", response.headers["Retry-After"].present?)
    body = JSON.parse(response.body)
    assert_equal("Rate limited error code", "rate_limited", body["error"])

    # Missing territory header
    post "/conduits/v1/polls",
         params: {},
         as: :json

    assert_status(401, "Missing territory header returns 401")

    # Unknown territory
    post "/conduits/v1/polls",
         params: {},
         headers: { "X-Nexus-Territory-Id" => "00000000-0000-0000-0000-000000000000" },
         as: :json

    assert_status(401, "Unknown territory returns 401")

    # Invalid sandbox profile in directive creation
    post "/mothership/api/v1/facilities/#{@facility.id}/directives",
         params: {
           command: "echo bad",
           sandbox_profile: "super_admin_mode",
         },
         headers: { "X-User-Id" => @user.id },
         as: :json

    assert_status(422, "Invalid sandbox profile returns 422")

    # Invalid stream in log_chunks (create a running directive first for this)
    # Using a fresh directive for isolation
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

    assert_status(422, "Invalid stream returns 422")

    # Invalid finished status
    post "/conduits/v1/directives/#{d3.id}/finished",
         params: { status: "exploded", exit_code: 42 },
         headers: directive_headers_for(token3),
         as: :json

    assert_status(422, "Invalid finished status returns 422")

    # Invalid diff_base64 should be rejected with 422
    post "/conduits/v1/directives/#{d3.id}/finished",
         params: { status: "failed", exit_code: 1, diff_base64: "not base64" },
         headers: directive_headers_for(token3),
         as: :json

    assert_status(422, "Invalid diff_base64 returns 422")

    # diff_base64 too large should be rejected with 422 (limits.max_diff_bytes)
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

    assert_status(422, "Oversize diff_base64 returns 422")

    post "/conduits/v1/directives/#{d5.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token5),
         as: :json

    assert_status(200, "Finish after oversize diff rejection returns 200")

    # finished without started (leased -> implicit start)
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

    assert_status(200, "Finished without started returns 200")
    body4 = JSON.parse(response.body)
    assert_true("Finished without started ok", body4["ok"])
    assert_false("Finished without started is not duplicate", body4["duplicate"])
    assert_equal("Finished without started final_state", "failed", body4["final_state"])

    post "/conduits/v1/directives/#{d4.id}/finished",
         params: { status: "failed", exit_code: 1 },
         headers: directive_headers_for(token4),
         as: :json

    assert_status(200, "Finished without started retry returns 200")
    body5 = JSON.parse(response.body)
    assert_true("Finished without started retry ok", body5["ok"])
    assert_true("Finished without started retry duplicate", body5["duplicate"])

    # Clean up: properly finish this directive
    d3.succeed!
    d3.facility.unlock! if d3.facility.locked?

    puts ""
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

  def section(title)
    puts "-" * 60
    puts "  #{title}"
    puts "-" * 60
  end

  def assert_status(expected, message)
    actual = response.status
    if actual == expected
      pass(message)
    else
      fail_test(message, "expected HTTP #{expected}, got #{actual}: #{response.body[0..200]}")
    end
  end

  def assert_equal(message, expected, actual)
    if expected == actual
      pass(message)
    else
      fail_test(message, "expected #{expected.inspect}, got #{actual.inspect}")
    end
  end

  def assert_true(message, value)
    if value
      pass(message)
    else
      fail_test(message, "expected truthy, got #{value.inspect}")
    end
  end

  def assert_false(message, value)
    if !value
      pass(message)
    else
      fail_test(message, "expected falsy, got #{value.inspect}")
    end
  end

  def pass(message)
    @passed_count += 1
    puts "  \e[32m PASS\e[0m #{message}"
  end

  def fail_test(message, detail)
    @failed_count += 1
    @errors << { message: message, detail: detail }
    puts "  \e[31m FAIL\e[0m #{message}"
    puts "         #{detail}"
  end

  def print_summary
    puts ""
    puts "=" * 60
    total = @passed_count + @failed_count
    if @failed_count == 0
      puts "  \e[32mALL #{total} TESTS PASSED\e[0m"
    else
      puts "  \e[31m#{@failed_count} of #{total} TESTS FAILED\e[0m"
      puts ""
      @errors.each_with_index do |err, i|
        puts "  #{i + 1}. #{err[:message]}"
        puts "     #{err[:detail]}"
      end
    end
    puts "=" * 60
    puts ""

    exit(1) if @failed_count > 0
  end

  # Required by ActionDispatch::Integration::Runner
  def app
    @app
  end
end

ConduitsE2ETest.new.run_all
