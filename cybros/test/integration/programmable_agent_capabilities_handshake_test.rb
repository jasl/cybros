require "test_helper"

class ProgrammableAgentCapabilitiesHandshakeTest < ActiveSupport::TestCase
  test "inspection materializes a capability snapshot and later handshakes reuse the unchanged fast path" do
    handshake_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "capabilities.handshake" => lambda do |params, base_result, _identity|
            handshake_calls << params.deep_dup
            base_result
          end,
        },
      ).start
    program = create_program!
    deployment = create_registered_deployment!(program: program, endpoint_url: server.rpc_url)

    inspect_agent_runtime!(agent: deployment)
    deployment.reload

    first_snapshot = deployment.capability_snapshot.deep_dup
    handshake_result = Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)

    assert_equal "refreshed", first_snapshot.fetch("status")
    assert_equal "agent_capabilities_changed", first_snapshot.fetch("refresh_reason")
    assert_equal "unchanged", handshake_result.fetch("status")
    assert_equal first_snapshot.fetch("capability_registry_snapshot_id"), deployment.reload.capability_snapshot.fetch("capability_registry_snapshot_id")
    assert_equal first_snapshot.fetch("kernel_capability_registry_version"), handshake_result.fetch("kernel_capability_registry_version")
    assert_equal "fixture-agent-capabilities:v1", first_snapshot.fetch("agent_capabilities_version")
    assert_includes deployment.supported_methods, "capabilities.handshake"
    assert_includes deployment.supported_methods, "capabilities.refresh"
    assert_equal 2, handshake_calls.size
    assert_nil handshake_calls.first["cached_agent_capabilities_version"]
    assert_equal "fixture-agent-capabilities:v1", handshake_calls.second["cached_agent_capabilities_version"]
  ensure
    server&.shutdown
  end

  test "bundled default inspection also materializes the capability snapshot through handshake" do
    program = Agents::Creator.create_from_bundled_source!(name: "Default assistant", bundled_agent_key: "default")
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

    inspect_agent_runtime!(agent: deployment)

    deployment.reload
    assert_includes deployment.supported_methods, "capabilities.handshake"
    assert_includes deployment.supported_methods, "capabilities.refresh"
    assert_equal "refreshed", deployment.capability_snapshot.fetch("status")
    assert_equal "default-agent-capabilities:v1", deployment.capability_snapshot.fetch("agent_capabilities_version")
    assert_match(/\Acsnap_/, deployment.capability_snapshot.fetch("capability_registry_snapshot_id"))
  ensure
    host&.shutdown
  end

  test "inspection marks deployment unhealthy when handshake contract validation fails" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "capabilities.handshake" => lambda do |_params, _base_result, _identity|
            {
            "status" => "refreshed",
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
            }
          end,
        },
      ).start
    program = create_program!
    deployment = create_registered_deployment!(program: program, endpoint_url: server.rpc_url)

    error =
      assert_raises(AgentCore::ValidationError) do
        inspect_agent_runtime!(agent: deployment)
      end

    deployment.reload
    assert_equal "cybros.programmable_agent.capability_handshake.agent_tool_catalog_is_required_for_refreshed_response", error.code
    assert_equal "inactive", deployment.status
    assert_equal "unhealthy", deployment.health_status
    assert_includes deployment.inspection_details.fetch("error"), "agent_tool_catalog"
  ensure
    server&.shutdown
  end

  private

    def create_program!
      create_agent_record!(
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
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
        health_status: "unknown",
        protocol_version: "agent_rpc.v1",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end
end
