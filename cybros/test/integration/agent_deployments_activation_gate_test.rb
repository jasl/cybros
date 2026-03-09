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
end
