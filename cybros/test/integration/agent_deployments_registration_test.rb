require "test_helper"
require "json"
require "tmpdir"

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

  test "new registration form allows a blank endpoint url for Cybros-managed local deployments" do
    sign_in_owner!
    program = create_program!

    get new_system_settings_agent_deployment_path

    assert_response :success
    assert_includes response.body, program.name
    assert_includes response.body, "Leave blank to let Cybros allocate and manage a local endpoint"
    assert_select 'input[name="agent_deployment[endpoint_url]"][required]', count: 0
  end

  test "registration allocates a unique local endpoint and writes runtime config when endpoint url is blank" do
    sign_in_owner!
    program = create_program!
    fingerprints = Array.new(2) { |index| "fixture-managed-local-#{index}-#{SecureRandom.hex(4)}" }

    Dir.mktmpdir("cybros-agent-runtime") do |workspace_root|
      configure_agent_workspace_root!(workspace_root)

      assert_difference -> { AgentDeployment.count }, +2 do
        fingerprints.each_with_index do |fingerprint, index|
          post system_settings_agent_deployments_path, params: {
            agent_deployment: {
              agent_program_id: program.id,
              transport_kind: "http_jsonrpc",
              endpoint_url: "",
              deployment_bearer_secret_ref: "secret://fixture-#{index}",
              deployment_fingerprint: fingerprint,
            },
          }

          assert_redirected_to system_settings_agent_deployment_path(AgentDeployment.order(:created_at).last)
        end
      end

      deployments = fingerprints.map { |fingerprint| AgentDeployment.find_by!(deployment_fingerprint: fingerprint) }
      ports = deployments.map { |deployment| deployment.transport_config.fetch("port") }

      assert_equal 2, ports.uniq.size

      deployments.each_with_index do |deployment, index|
        runtime_config_path = deployment.transport_config.fetch("runtime_config_path")

        assert_equal "inactive", deployment.status
        assert_equal "unknown", deployment.health_status
        assert_equal "http://127.0.0.1:#{ports[index]}/rpc", deployment.endpoint_url
        assert_equal "127.0.0.1", deployment.transport_config.fetch("host")
        assert_equal "127.0.0.1", deployment.transport_config.fetch("bind_host")
        assert_equal "/rpc", deployment.transport_config.fetch("rpc_path")
        assert File.exist?(runtime_config_path), "expected runtime config file to exist"

        config_payload = JSON.parse(File.read(runtime_config_path))
        assert_equal deployment.id, config_payload.dig("deployment", "id")
        assert_equal deployment.deployment_fingerprint, config_payload.dig("deployment", "deployment_fingerprint")
        assert_equal deployment.deployment_bearer_secret_ref, config_payload.dig("deployment", "deployment_bearer_secret_ref")
        assert_equal deployment.endpoint_url, config_payload.dig("transport", "endpoint_url")
        assert_equal deployment.transport_config.fetch("port"), config_payload.dig("transport", "port")
        assert_equal program.absolute_local_path.to_s, config_payload.dig("agent_program", "source_root")
      end
    end
  end

  test "registration honors compose managed local host overrides" do
    sign_in_owner!
    program = create_program!
    fingerprint = "fixture-compose-managed-local-#{SecureRandom.hex(4)}"

    Dir.mktmpdir("cybros-agent-runtime") do |workspace_root|
      configure_agent_workspace_root!(workspace_root)

      with_env(
        "CYBROS_MANAGED_AGENT_PUBLIC_HOST" => "agent_deployments",
        "CYBROS_MANAGED_AGENT_BIND_HOST" => "0.0.0.0",
      ) do
        post system_settings_agent_deployments_path, params: {
          agent_deployment: {
            agent_program_id: program.id,
            transport_kind: "http_jsonrpc",
            endpoint_url: "",
            deployment_bearer_secret_ref: "secret://fixture-compose",
            deployment_fingerprint: fingerprint,
          },
        }
      end

      deployment = AgentDeployment.find_by!(deployment_fingerprint: fingerprint)

      assert_equal "http://agent_deployments:#{deployment.allocated_port}/rpc", deployment.endpoint_url
      assert_equal "agent_deployments", deployment.transport_config.fetch("host")
      assert_equal "0.0.0.0", deployment.transport_config.fetch("bind_host")
    end
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

    def configure_agent_workspace_root!(path)
      runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
      runtime_setting.assign_attributes(
        default_worker_concurrency: RuntimeSetting::DEFAULT_WORKER_CONCURRENCY,
        agent_workspace_root: path,
        queue_overrides: {},
        alert_thresholds: {},
      )
      runtime_setting.save!
    end

    def with_env(values)
      original = values.to_h { |key, _value| [key, ENV[key]] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      original.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
end
