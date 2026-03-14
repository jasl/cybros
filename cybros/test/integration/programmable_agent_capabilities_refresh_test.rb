require "test_helper"

class ProgrammableAgentCapabilitiesRefreshTest < ActiveSupport::TestCase
  test "handshake refreshes cached snapshots when the kernel registry version changes" do
    handshake_versions = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "capabilities.handshake" => lambda do |params, base_result, _identity|
            handshake_versions << params["kernel_capability_registry_version"]
            base_result
          end,
        },
      ).start
    program = create_program!
    deployment = create_registered_deployment!(program: program, endpoint_url: server.rpc_url)

    inspect_agent_runtime!(agent: deployment)
    original_snapshot = deployment.reload.capability_snapshot.deep_dup

    with_kernel_catalog(version: "kernel:v2") do
      refreshed = Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment.reload)

      assert_equal "refreshed", refreshed.fetch("status")
      assert_equal "kernel_registry_changed", refreshed.fetch("refresh_reason")
      assert_equal "kernel:v2", refreshed.fetch("kernel_capability_registry_version")
      assert_not_equal original_snapshot.fetch("capability_registry_snapshot_id"), refreshed.fetch("capability_registry_snapshot_id")
    end

    assert_equal [original_snapshot.fetch("kernel_capability_registry_version"), "kernel:v2"], handshake_versions
  ensure
    server&.shutdown
  end

  test "handshake refreshes when agent capabilities change and manual refresh bypasses unchanged fast path" do
    agent_capabilities_version = "fixture-agent-capabilities:v1"
    refresh_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "capabilities.handshake" => lambda do |params, _base_result, _identity|
            capability_result(
              params: params,
              agent_capabilities_version: agent_capabilities_version,
            )
          end,
          "capabilities.refresh" => lambda do |params, _base_result, _identity|
            refresh_calls << params.deep_dup
            capability_result(
              params: params,
              agent_capabilities_version: agent_capabilities_version,
              force_refresh: true,
            )
          end,
        },
      ).start
    program = create_program!
    deployment = create_registered_deployment!(program: program, endpoint_url: server.rpc_url)

    inspect_agent_runtime!(agent: deployment)
    original_snapshot = deployment.reload.capability_snapshot.deep_dup

    agent_capabilities_version = "fixture-agent-capabilities:v2"
    refreshed = Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment.reload)

    assert_equal "refreshed", refreshed.fetch("status")
    assert_equal "agent_capabilities_changed", refreshed.fetch("refresh_reason")
    assert_equal "fixture-agent-capabilities:v2", refreshed.fetch("agent_capabilities_version")
    assert_not_equal original_snapshot.fetch("capability_registry_snapshot_id"), refreshed.fetch("capability_registry_snapshot_id")

    manual = Cybros::ProgrammableAgent::CapabilityHandshake.refresh!(deployment: deployment.reload, reason: "manual")

    assert_equal "refreshed", manual.fetch("status")
    assert_equal "manual", manual.fetch("refresh_reason")
    assert_equal "fixture-agent-capabilities:v2", manual.fetch("agent_capabilities_version")
    assert_equal "manual", refresh_calls.last.fetch("reason")
  ensure
    server&.shutdown
  end

  test "manual refresh fails fast when the agent replies with unchanged" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "capabilities.refresh" => {
            "status" => "unchanged",
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
          },
        },
      ).start
    program = create_program!
    deployment = create_registered_deployment!(program: program, endpoint_url: server.rpc_url)

    inspect_agent_runtime!(agent: deployment)

    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::CapabilityHandshake.refresh!(deployment: deployment.reload, reason: "manual")
      end

    assert_equal "cybros.programmable_agent.capability_handshake.capabilities_refresh_must_return_refreshed", error.code
  ensure
    server&.shutdown
  end

  private

    def capability_result(params:, agent_capabilities_version:, force_refresh: false)
      cached_version = params["cached_agent_capabilities_version"].to_s
      return { "status" => "unchanged", "agent_capabilities_version" => agent_capabilities_version } if !force_refresh && cached_version == agent_capabilities_version

      {
        "status" => "refreshed",
        "agent_capabilities_version" => agent_capabilities_version,
        "agent_tool_catalog" => [],
      }
    end

    def with_kernel_catalog(version:)
      catalog_klass = Cybros::ProgrammableAgent::KernelCapabilityCatalog.singleton_class
      original_method = catalog_klass.instance_method(:current)

      catalog_klass.send(:define_method, :current) do
        original = original_method.bind(Cybros::ProgrammableAgent::KernelCapabilityCatalog).call
        original.with(kernel_capability_registry_version: version)
      end
      yield
    ensure
      catalog_klass.send(:define_method, :current, original_method)
    end

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

    def create_registered_deployment!(program:, endpoint_url:)
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
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
