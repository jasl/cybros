require "test_helper"

class AgentDeploymentTest < ActiveSupport::TestCase
  test "requires connectivity and inspection fields" do
    deployment =
      build_deployment(
        transport_kind: nil,
        deployment_bearer_secret_ref: nil,
        contract_fingerprint: nil,
        deployment_fingerprint: nil,
        protocol_version: nil,
        supported_methods: [],
      )

    refute_predicate deployment, :valid?
    assert_includes deployment.errors[:transport_kind], "can't be blank"
    assert_includes deployment.errors[:deployment_bearer_secret_ref], "can't be blank"
    assert_includes deployment.errors[:contract_fingerprint], "can't be blank"
    assert_includes deployment.errors[:deployment_fingerprint], "can't be blank"
    assert_includes deployment.errors[:protocol_version], "can't be blank"
    assert deployment.errors[:supported_methods].any?
  end

  test "allows only one active deployment per agent program" do
    program = build_program
    build_deployment(agent_program: program).save!

    duplicate = build_deployment(agent_program: program, deployment_fingerprint: "deployment:v2")

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:agent_program_id], "has already been taken"

    inactive = build_deployment(agent_program: program, status: "inactive", deployment_fingerprint: "deployment:v2")
    assert_predicate inactive, :valid?
  end

  test "managed local http jsonrpc allocations require runtime config ownership metadata" do
    deployment =
      build_deployment(
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:47101/rpc",
        transport_config: { "port" => 47_101 },
      )

    refute_predicate deployment, :valid?
    assert_includes deployment.errors[:transport_config], "must include runtime_config_path for managed local endpoints"

    deployment.transport_config = {
      "host" => "127.0.0.1",
      "port" => 47_101,
      "rpc_path" => "/rpc",
      "runtime_config_path" => "/tmp/cybros-runtime-configs/deployment-v1.json",
    }

    assert_predicate deployment, :valid?
  end

  private

  def build_deployment(attributes = {})
    AgentDeployment.new(
      {
        agent_program: build_program,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: "contract:v1",
        deployment_fingerprint: "deployment:v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        transport_config: {},
        manifest_snapshot: { "name" => "Fixture" },
        schema_snapshot: { "protocol_version" => "agent_rpc.v1" },
        capability_snapshot: { "supports" => %w[before_agent_step] },
        inspection_details: { "healthy" => true },
      }.merge(attributes),
    )
  end

  def build_program
    AgentProgram.create!(
      name: "Fixture Program",
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      manifest_snapshot: { "name" => "Fixture" },
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )
  end
end
