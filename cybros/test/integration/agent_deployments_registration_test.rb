require "test_helper"

class AgentDeploymentsRegistrationTest < ActionDispatch::IntegrationTest
  test "registers a deployment from operator-managed connection settings" do
    sign_in_owner!
    program = create_program!
    server = Cybros::ProgrammableAgentFixture::Server.new.start

    assert_difference -> { AgentDeployment.count }, +1 do
      post system_settings_agent_deployments_path, params: {
        agent_deployment: {
          agent_program_id: program.id,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          deployment_fingerprint: "fixture-deployment-v1",
        },
      }
    end

    deployment = AgentDeployment.order(:created_at).last
    assert_redirected_to system_settings_agent_deployment_path(deployment)
    assert_equal program.id, deployment.agent_program_id
    assert_equal "inactive", deployment.status
    assert_equal "unknown", deployment.health_status
    assert_equal server.rpc_url, deployment.endpoint_url
    assert_equal program.published_contract_fingerprint, deployment.contract_fingerprint

    get system_settings_agent_deployment_path(deployment)
    assert_response :success
    assert_includes response.body, "fixture-deployment-v1"
    assert_includes response.body, server.rpc_url
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
end
