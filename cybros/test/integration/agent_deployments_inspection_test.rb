require "test_helper"

class AgentDeploymentsInspectionTest < ActionDispatch::IntegrationTest
  test "inspects a registered deployment through initialize describe health and schemas" do
    sign_in_owner!
    program = create_program!
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)

    assert_redirected_to system_settings_agent_deployment_path(deployment)

    deployment.reload
    assert_equal "healthy", deployment.health_status
    assert_equal "agent_rpc.v1", deployment.protocol_version
    assert_equal "fixture-ruby-sdk/1.0", deployment.agent_sdk_version
    assert_includes deployment.supported_methods, "before_agent_step"
    assert_equal "Fixture Programmable Agent", deployment.manifest_snapshot.fetch("name")
    assert_equal({ "type" => "object", "properties" => {} }, deployment.schema_snapshot.fetch("global_config_schema"))
    assert_equal true, deployment.inspection_details.dig("health", "healthy")
  ensure
    server&.shutdown
  end

  test "inspects the bundled default deployment through the bundled host" do
    sign_in_owner!
    program = AgentPrograms::Creator.create_from_bundled_source!(name: "Default assistant", bundled_agent_key: "default")
    host =
      Cybros::BundledAgentHost::Application.new(
        source_root: Rails.root.join("agents/default"),
        deployment_fingerprint: "bundled-default-test",
        required_bearer: "secret://bundled",
      ).start
    deployment = create_registered_deployment!(
      program: program,
      endpoint_url: host.rpc_url,
      deployment_fingerprint: "bundled-default-test",
      deployment_bearer_secret_ref: "secret://bundled",
    )

    post inspect_system_settings_agent_deployment_path(deployment)

    assert_redirected_to system_settings_agent_deployment_path(deployment)

    deployment.reload
    assert_equal "healthy", deployment.health_status
    assert_includes deployment.supported_methods, "before_agent_step"
    assert_equal "default", deployment.manifest_snapshot.dig("identity", "agent_program_key")
  ensure
    host&.shutdown
  end

  test "rejects inspection when deployment identity claims do not match the registered binding" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "deployment_fingerprint" => "unexpected-fingerprint" },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)

    assert_response :unprocessable_entity
    deployment.reload
    assert_equal "inactive", deployment.status
    assert_equal "unhealthy", deployment.health_status
    assert_includes deployment.inspection_details.fetch("error"), "identity mismatch"
  ensure
    server&.shutdown
  end

  test "rejects inspection when initialize omits protocol version" do
    sign_in_owner!
    program = create_program!
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "protocol_version" => nil },
      ).start
    deployment = create_registered_deployment!(program:, endpoint_url: server.rpc_url)

    post inspect_system_settings_agent_deployment_path(deployment)

    assert_response :unprocessable_entity
    deployment.reload
    assert_equal "inactive", deployment.status
    assert_equal "unhealthy", deployment.health_status
    assert_includes deployment.inspection_details.fetch("error"), "protocol_version"
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

    def create_registered_deployment!(program:, endpoint_url:, deployment_fingerprint: "fixture-deployment-v1", deployment_bearer_secret_ref: "secret://fixture")
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
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
