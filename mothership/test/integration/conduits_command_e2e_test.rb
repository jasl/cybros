require "test_helper"

class ConduitsCommandE2ETest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown do
    Conduits::AuditEvent.delete_all
    Conduits::Command.find_each { |c| c.result_attachment.purge if c.result_attachment.attached? }
    Conduits::Command.delete_all
    Conduits::BridgeEntity.delete_all
    Conduits::LogChunk.delete_all
    Conduits::Directive.find_each { |d| d.diff_blob.purge if d.diff_blob.attached? }
    Conduits::Directive.delete_all
    Conduits::Facility.delete_all
    Conduits::EnrollmentToken.delete_all
    Conduits::Territory.delete_all
    User.delete_all
    Account.delete_all
  end

  test "full command track lifecycle: mobile enrollment, command dispatch via REST, result" do
    seed_data
    phase_mobile_enrollment
    phase_heartbeat_with_capabilities
    phase_command_create_and_pending_poll
    phase_command_result_submission
    phase_command_cancel
    phase_command_timeout
  end

  test "full command track lifecycle: bridge enrollment, entity sync, command dispatch" do
    seed_data
    phase_bridge_enrollment
    phase_bridge_heartbeat_with_entities
    phase_bridge_command_flow
  end

  test "existing directive flow still works after refactor" do
    seed_data
    phase_legacy_directive_flow
  end

  private

  def seed_data
    @account = Account.create!(name: "cmd-e2e-account")
    @user = User.create!(account: @account, name: "cmd-e2e-user")

    @mobile_enrollment_record, @mobile_enrollment_token = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour, labels: {}
    )
    @bridge_enrollment_record, @bridge_enrollment_token = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour, labels: {}
    )
    @server_enrollment_record, @server_enrollment_token = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour, labels: {}
    )
  end

  # ─── Mobile Enrollment ─────────────────────────────────────

  def phase_mobile_enrollment
    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: @mobile_enrollment_token,
           name: "James's iPhone",
           kind: "mobile",
           platform: "ios",
           display_name: "James's iPhone",
           labels: { device_model: "iPhone 16 Pro" },
         },
         as: :json

    assert_response 201, "Mobile enrollment returns 201"
    body = JSON.parse(response.body)
    @mobile_territory_id = body["territory_id"]
    assert_equal "mobile", body["kind"]

    territory = Conduits::Territory.find(@mobile_territory_id)
    assert_equal "mobile", territory.kind
    assert_equal "ios", territory.platform
    assert_equal "James's iPhone", territory.display_name
    assert_equal "online", territory.status
  end

  def phase_heartbeat_with_capabilities
    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.6.0",
           labels: { os: "ios", device_model: "iPhone 16 Pro" },
           capacity: { foreground: true, battery_level: 85, network_type: "wifi" },
           capabilities: ["camera.snap", "camera.record", "location.get", "audio.record"],
         },
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 200
    territory = Conduits::Territory.find(@mobile_territory_id)
    assert_equal ["camera.snap", "camera.record", "location.get", "audio.record"], territory.capabilities
  end

  def phase_command_create_and_pending_poll
    # Create a command directly in DB (simulating Agent/API creation)
    territory = Conduits::Territory.find(@mobile_territory_id)
    @command = Conduits::Command.create!(
      account: @account,
      territory: territory,
      capability: "camera.snap",
      params: { facing: "back", quality: 80 },
      timeout_seconds: 30
    )
    assert_equal "queued", @command.state

    # Territory polls for pending commands
    get "/conduits/v1/commands/pending",
        params: { max: 5 },
        headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
        as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal 1, body["commands"].length

    cmd = body["commands"][0]
    assert_equal @command.id, cmd["command_id"]
    assert_equal "camera.snap", cmd["capability"]
    assert_equal({ "facing" => "back", "quality" => 80 }, cmd["params"])
    assert_equal 30, cmd["timeout_seconds"]
    assert_nil cmd["bridge_entity_ref"]

    @command.reload
    assert_equal "dispatched", @command.state
    assert @command.dispatched_at.present?

    # Second poll returns empty
    get "/conduits/v1/commands/pending",
        headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
        as: :json

    body2 = JSON.parse(response.body)
    assert_equal 0, body2["commands"].length
    assert body2["retry_after_seconds"] > 0
  end

  def phase_command_result_submission
    # Simulate a photo result with base64 attachment
    jpeg_data = "\xFF\xD8\xFF\xE0mock-jpeg-data"

    post "/conduits/v1/commands/#{@command.id}/result",
         params: {
           status: "completed",
           result: { width: 3024, height: 4032, content_type: "image/jpeg" },
           attachment_base64: Base64.strict_encode64(jpeg_data),
           attachment_content_type: "image/jpeg",
           attachment_filename: "snap_20260227_143022.jpg",
         },
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "completed", body["final_state"]

    @command.reload
    assert_equal "completed", @command.state
    assert @command.completed_at.present?
    assert_equal({ "width" => 3024, "height" => 4032, "content_type" => "image/jpeg" }, @command.result)
    assert @command.result_attachment.attached?, "Result attachment should be attached"
    assert_equal jpeg_data.b, @command.result_attachment.download

    # Idempotent retry — must send identical status + result for hash to match
    post "/conduits/v1/commands/#{@command.id}/result",
         params: {
           status: "completed",
           result: { width: 3024, height: 4032, content_type: "image/jpeg" },
         },
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 200
    body2 = JSON.parse(response.body)
    assert body2["duplicate"]

    # Mismatched result should return 409
    post "/conduits/v1/commands/#{@command.id}/result",
         params: { status: "completed", result: { totally: "different" } },
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 409
  end

  def phase_command_cancel
    territory = Conduits::Territory.find(@mobile_territory_id)
    cancel_cmd = Conduits::Command.create!(
      account: @account, territory: territory,
      capability: "location.get", timeout_seconds: 30
    )

    post "/conduits/v1/commands/#{cancel_cmd.id}/cancel",
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "canceled", body["final_state"]

    cancel_cmd.reload
    assert_equal "canceled", cancel_cmd.state

    # Cancel already terminal
    post "/conduits/v1/commands/#{cancel_cmd.id}/cancel",
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 200
    body2 = JSON.parse(response.body)
    assert body2["already_terminal"]
  end

  def phase_command_timeout
    territory = Conduits::Territory.find(@mobile_territory_id)
    timeout_cmd = Conduits::Command.create!(
      account: @account, territory: territory,
      capability: "camera.snap", timeout_seconds: 1
    )
    timeout_cmd.update_column(:created_at, 10.seconds.ago)

    Conduits::CommandTimeoutJob.perform_now

    timeout_cmd.reload
    assert_equal "timed_out", timeout_cmd.state
  end

  # ─── Bridge Enrollment ─────────────────────────────────────

  def phase_bridge_enrollment
    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: @bridge_enrollment_token,
           name: "Home Assistant Bridge",
           kind: "bridge",
           platform: "homeassistant",
           labels: { ha_version: "2026.2" },
         },
         as: :json

    assert_response 201
    body = JSON.parse(response.body)
    @bridge_territory_id = body["territory_id"]
    assert_equal "bridge", body["kind"]

    territory = Conduits::Territory.find(@bridge_territory_id)
    assert_equal "bridge", territory.kind
    assert_equal "homeassistant", territory.platform
  end

  def phase_bridge_heartbeat_with_entities
    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.6.0",
           labels: { os: "linux" },
           bridge_entities: [
             {
               entity_ref: "light.living_room",
               entity_type: "light",
               display_name: "Living Room Light",
               capabilities: ["iot.light.control", "iot.light.brightness"],
               location: "home/living-room",
               state: { on: true, brightness: 80 },
               available: true,
             },
             {
               entity_ref: "sensor.temp_living",
               entity_type: "sensor",
               display_name: "Living Room Temp",
               capabilities: ["sensor.temperature"],
               location: "home/living-room",
               state: { value: 22.5, unit: "°C" },
               available: true,
             },
           ],
         },
         headers: { "X-Nexus-Territory-Id" => @bridge_territory_id },
         as: :json

    assert_response 200

    bridge = Conduits::Territory.find(@bridge_territory_id)
    assert_equal 2, bridge.bridge_entities.count

    light = bridge.bridge_entities.find_by(entity_ref: "light.living_room")
    assert_equal "light", light.entity_type
    assert_equal "Living Room Light", light.display_name
    assert_includes light.capabilities, "iot.light.control"
    assert light.available

    # Second heartbeat: update existing + remove missing
    post "/conduits/v1/territories/heartbeat",
         params: {
           nexus_version: "0.6.0",
           bridge_entities: [
             {
               entity_ref: "light.living_room",
               entity_type: "light",
               display_name: "Living Room Light (Updated)",
               capabilities: ["iot.light.control", "iot.light.brightness", "iot.light.color"],
               state: { on: false },
               available: true,
             },
           ],
         },
         headers: { "X-Nexus-Territory-Id" => @bridge_territory_id },
         as: :json

    assert_response 200

    light.reload
    assert_equal "Living Room Light (Updated)", light.display_name
    assert_includes light.capabilities, "iot.light.color"

    sensor = bridge.bridge_entities.find_by(entity_ref: "sensor.temp_living")
    sensor.reload
    refute sensor.available, "Missing entity should be marked unavailable"
  end

  def phase_bridge_command_flow
    bridge = Conduits::Territory.find(@bridge_territory_id)
    light = bridge.bridge_entities.find_by(entity_ref: "light.living_room")

    cmd = Conduits::Command.create!(
      account: @account,
      territory: bridge,
      bridge_entity: light,
      capability: "iot.light.control",
      params: { action: "turn_on", service_data: { brightness: 200 } },
      timeout_seconds: 30
    )

    # Bridge polls for pending
    get "/conduits/v1/commands/pending",
        headers: { "X-Nexus-Territory-Id" => @bridge_territory_id },
        as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal 1, body["commands"].length
    assert_equal "light.living_room", body["commands"][0]["bridge_entity_ref"]
    assert_equal "iot.light.control", body["commands"][0]["capability"]

    # Bridge submits result
    post "/conduits/v1/commands/#{cmd.id}/result",
         params: {
           status: "completed",
           result: { action: "turned_on" },
         },
         headers: { "X-Nexus-Territory-Id" => @bridge_territory_id },
         as: :json

    assert_response 200
    cmd.reload
    assert_equal "completed", cmd.state
    assert_equal({ "action" => "turned_on" }, cmd.result)
  end

  # ─── Legacy Directive Flow ─────────────────────────────────

  def phase_legacy_directive_flow
    # Enroll a server territory (legacy path)
    post "/conduits/v1/territories/enroll",
         params: {
           enroll_token: @server_enrollment_token,
           name: "e2e-server",
           kind: "server",
           platform: "linux",
           labels: { arch: "amd64", os: "linux" },
         },
         as: :json

    assert_response 201
    body = JSON.parse(response.body)
    server_territory_id = body["territory_id"]
    assert_equal "server", body["kind"]

    territory = Conduits::Territory.find(server_territory_id)
    assert_equal "server", territory.kind
    assert_equal "linux", territory.platform
    assert territory.supports_directives?

    # Create a facility for directive
    facility = Conduits::Facility.create!(
      account: @account, owner: @user,
      territory: territory,
      kind: "repo", retention_policy: "keep_last_5",
      repo_url: "https://github.com/example/test-repo"
    )

    # Create directive
    post "/mothership/api/v1/facilities/#{facility.id}/directives",
         params: {
           command: "echo 'testing directive after refactor'",
           sandbox_profile: "untrusted",
           timeout_seconds: 60,
         },
         headers: { "X-Account-Id" => @account.id, "X-User-Id" => @user.id },
         as: :json

    assert_response 201
    body = JSON.parse(response.body)
    directive_id = body["directive_id"]
    assert_equal "queued", body["state"]

    # Poll and claim
    post "/conduits/v1/polls",
         params: { supported_sandbox_profiles: ["untrusted"] },
         headers: { "X-Nexus-Territory-Id" => server_territory_id },
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal 1, body["directives"].length
    directive_token = body["directives"][0]["directive_token"]

    # Start and finish
    post "/conduits/v1/directives/#{directive_id}/started",
         params: { nexus_version: "0.6.0", sandbox_version: "0.6.0" },
         headers: {
           "X-Nexus-Territory-Id" => server_territory_id,
           "Authorization" => "Bearer #{directive_token}",
         },
         as: :json

    assert_response 200

    post "/conduits/v1/directives/#{directive_id}/finished",
         params: { status: "succeeded", exit_code: 0 },
         headers: {
           "X-Nexus-Territory-Id" => server_territory_id,
           "Authorization" => "Bearer #{directive_token}",
         },
         as: :json

    assert_response 200
    body = JSON.parse(response.body)
    assert_equal "succeeded", body["final_state"]
  end

  # ─── Edge Cases ────────────────────────────────────────────

  test "command result with wrong territory returns 404 (scoped lookup)" do
    seed_data
    phase_mobile_enrollment

    # Create a second territory
    _, token2 = Conduits::EnrollmentToken.generate!(
      account: @account, user: @user, ttl: 1.hour
    )
    post "/conduits/v1/territories/enroll",
         params: { enroll_token: token2, name: "other", kind: "mobile", platform: "android" },
         as: :json
    assert_response 201
    other_id = JSON.parse(response.body)["territory_id"]

    territory = Conduits::Territory.find(@mobile_territory_id)
    territory.update!(capabilities: ["camera.snap"])
    cmd = Conduits::Command.create!(
      account: @account, territory: territory,
      capability: "camera.snap", timeout_seconds: 30
    )

    # Command belongs to @mobile_territory_id but request comes from other_id.
    # Scoped lookup via current_territory.commands returns not_found (defense-in-depth).
    post "/conduits/v1/commands/#{cmd.id}/result",
         params: { status: "completed", result: {} },
         headers: { "X-Nexus-Territory-Id" => other_id },
         as: :json

    assert_response 404
  end

  test "command result with invalid status returns 422" do
    seed_data
    phase_mobile_enrollment

    territory = Conduits::Territory.find(@mobile_territory_id)
    territory.update!(capabilities: ["camera.snap"])
    cmd = Conduits::Command.create!(
      account: @account, territory: territory,
      capability: "camera.snap", timeout_seconds: 30
    )
    cmd.dispatch!

    post "/conduits/v1/commands/#{cmd.id}/result",
         params: { status: "exploded", result: {} },
         headers: { "X-Nexus-Territory-Id" => @mobile_territory_id },
         as: :json

    assert_response 422
  end

  test "pending command with unknown territory returns 401" do
    get "/conduits/v1/commands/pending",
        headers: { "X-Nexus-Territory-Id" => "00000000-0000-0000-0000-000000000000" },
        as: :json

    assert_response 401
  end

  test "enrollment with invalid kind returns 422" do
    account = Account.create!(name: "kind-test")
    user = User.create!(account: account, name: "kind-tester")
    _, token = Conduits::EnrollmentToken.generate!(
      account: account, user: user, ttl: 1.hour
    )

    post "/conduits/v1/territories/enroll",
         params: { enroll_token: token, name: "bad-kind", kind: "spaceship" },
         as: :json

    assert_response 422
  end
end
