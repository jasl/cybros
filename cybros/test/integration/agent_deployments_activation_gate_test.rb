require "test_helper"

class AgentDeploymentsActivationGateTest < ActionDispatch::IntegrationTest
  test "activates an inspected healthy deployment when protocol and methods match exactly" do
    sign_in_owner!
    program = create_program!
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)
    assert_redirected_to system_settings_agent_deployment_path(deployment)

    post activate_system_settings_agent_deployment_path(deployment)

    assert_redirected_to system_settings_agent_deployment_path(deployment)
    deployment.reload
    assert_equal "active", deployment.status
    assert_equal "healthy", deployment.health_status
    assert deployment.activated_at.present?
  ensure
    server&.shutdown
  end

  test "rejects activation when protocol version is not supported" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "protocol_version" => "agent_rpc.v2" },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)
    assert_redirected_to system_settings_agent_deployment_path(deployment)

    post activate_system_settings_agent_deployment_path(deployment)

    assert_response :unprocessable_entity
    deployment.reload
    assert_equal "inactive", deployment.status
  ensure
    server&.shutdown
  end

  test "rejects activation when required methods are missing or health is unhealthy" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: {
          "supported_methods" => %w[initialize agent.describe agent.health agent.schemas.get turn.prepare],
        },
        rpc_overrides: {
          "agent.health" => { "healthy" => false, "status" => "unhealthy" },
        },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)
    assert_redirected_to system_settings_agent_deployment_path(deployment)

    post activate_system_settings_agent_deployment_path(deployment)

    assert_response :unprocessable_entity
    deployment.reload
    assert_equal "inactive", deployment.status
  ensure
    server&.shutdown
  end

  test "activates when health inspection reports an alternate successful status label" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "agent.health" => { "healthy" => true, "status" => "ok" },
        },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)
    assert_redirected_to system_settings_agent_deployment_path(deployment)

    deployment.reload
    assert_equal "healthy", deployment.health_status

    post activate_system_settings_agent_deployment_path(deployment)

    assert_redirected_to system_settings_agent_deployment_path(deployment)
    deployment.reload
    assert_equal "active", deployment.status
  ensure
    server&.shutdown
  end

  test "rejects activation when turn.handle_error is missing from the inspected contract" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: {
          "supported_methods" => %w[
            initialize
            agent.describe
            agent.health
            agent.schemas.get
            turn.prepare
            turn.compose
          ],
        },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)
    assert_redirected_to system_settings_agent_deployment_path(deployment)

    post activate_system_settings_agent_deployment_path(deployment)

    assert_response :unprocessable_entity
    deployment.reload
    assert_equal "inactive", deployment.status
  ensure
    server&.shutdown
  end

  test "activation does not deactivate the old deployment before the new deployment is healthy" do
    sign_in_owner!
    program = create_program!
    active_server = Cybros::ProgrammableAgentFixture::Server.new.start
    candidate_server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "deployment_fingerprint" => "fixture-deployment-v2" },
        rpc_overrides: {
          "agent.health" => { "healthy" => false, "status" => "unhealthy" },
        },
      ).start
    active_deployment = create_active_deployment!(program:, endpoint_url: active_server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
    stale_session = create_open_session!(deployment: active_deployment)
    candidate = create_registered_deployment!(program:, endpoint_url: candidate_server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")

    post inspect_system_settings_agent_deployment_path(candidate)
    assert_redirected_to system_settings_agent_deployment_path(candidate)

    post activate_system_settings_agent_deployment_path(candidate)

    assert_response :unprocessable_entity
    assert_equal "active", active_deployment.reload.status
    assert_equal "open", stale_session.reload.status
    assert_equal "inactive", candidate.reload.status
  ensure
    active_server&.shutdown
    candidate_server&.shutdown
  end

  test "successful activation closes callback sessions on the replaced deployment" do
    sign_in_owner!
    program = create_program!
    active_server = Cybros::ProgrammableAgentFixture::Server.new.start
    candidate_server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "deployment_fingerprint" => "fixture-deployment-v2" },
      ).start
    active_deployment = create_active_deployment!(program:, endpoint_url: active_server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
    stale_session = create_open_session!(deployment: active_deployment)
    candidate = create_registered_deployment!(program:, endpoint_url: candidate_server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")

    post inspect_system_settings_agent_deployment_path(candidate)
    assert_redirected_to system_settings_agent_deployment_path(candidate)

    post activate_system_settings_agent_deployment_path(candidate)

    assert_redirected_to system_settings_agent_deployment_path(candidate)
    assert_equal "inactive", active_deployment.reload.status
    assert_equal "closed", stale_session.reload.status
    assert_equal "active", candidate.reload.status
  ensure
    active_server&.shutdown
    candidate_server&.shutdown
  end

  private

    def sign_in_owner!
      identity =
        Identity.create!(
          email: "admin@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      User.create!(identity: identity, role: :owner)

      post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_registered_deployment!(program:, endpoint_url:, deployment_fingerprint: "fixture-deployment-v1")
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
        health_status: "unknown",
        protocol_version: "agent_rpc.v1",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end

    def create_active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        transport_config: {},
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {
          "initialize" => { "identity" => { "deployment_fingerprint" => deployment_fingerprint } },
          "describe" => {},
          "health" => { "healthy" => true },
          "schemas" => {},
          "identity" => {
            "protocol_version" => "agent_rpc.v1",
            "deployment_fingerprint" => deployment_fingerprint,
            "supported_methods" => AgentDeployments::REQUIRED_METHODS,
          },
        },
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_open_session!(deployment:)
      conversation = create_conversation!
      conversation.update!(
        agent_program: deployment.agent_program,
        agent_config_schema_fingerprint: deployment.agent_program.config_schema_fingerprint,
      )

      AgentRPCSession.create!(
        agent_deployment: deployment,
        agent_program: deployment.agent_program,
        conversation: conversation,
        scope_type: "run_draft",
        scope_id: SecureRandom.uuid,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at,
        session_token_digest: Digest::SHA256.hexdigest("arpc_#{SecureRandom.hex(24)}"),
        allowed_methods: %w[conversation.settings.get],
        expires_at: 5.minutes.from_now.change(usec: 0),
        status: "open",
      )
    end
end
