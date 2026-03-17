require "test_helper"

class Cybros::ProgrammableAgent::RecognizedDeploymentResolverTest < ActiveSupport::TestCase
  test "normalizes initialize identity and capability snapshot into one recognized deployment" do
    runtime = create_runtime!

    recognized =
      Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: runtime.fetch(:initialize_result),
        capability_snapshot: runtime.fetch(:capability_snapshot),
      )

    assert_equal runtime.fetch(:agent).id, recognized.agent_id
    assert_equal runtime.fetch(:deployment).deployment_fingerprint, recognized.deployment_fingerprint
    assert_equal runtime.fetch(:capability_snapshot).fetch("agent_capabilities_version"), recognized.agent_capabilities_version
    assert_equal runtime.fetch(:capability_snapshot).fetch("hostname"), recognized.hostname
    assert_equal true, recognized.supports_upload
    assert_match(/\Arecognized_deployment:agent:/, recognized.recognized_deployment_key)
    assert_match(/\Asha256:/, recognized.identity_digest)
  end

  test "reuses the same recognized deployment for the same normalized runtime identity" do
    runtime = create_runtime!

    first =
      Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: runtime.fetch(:initialize_result),
        capability_snapshot: runtime.fetch(:capability_snapshot),
      )
    second =
      Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: runtime.fetch(:initialize_result),
        capability_snapshot: runtime.fetch(:capability_snapshot),
      )

    assert_equal first.id, second.id
    assert_equal first.identity_digest, second.identity_digest
  end

  test "creates a new recognized deployment when hard identity fields change" do
    runtime = create_runtime!
    first =
      Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: runtime.fetch(:initialize_result),
        capability_snapshot: runtime.fetch(:capability_snapshot),
      )

    changed_initialize_result =
      runtime.fetch(:initialize_result).deep_dup.tap do |payload|
        payload["identity"]["supported_methods"] = payload["identity"].fetch("supported_methods") + ["attachments.import"]
      end
    changed_capability_snapshot =
      runtime.fetch(:capability_snapshot).merge(
        "agent_capabilities_version" => "2026-03-14",
      )

    second =
      Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        initialize_result: changed_initialize_result,
        capability_snapshot: changed_capability_snapshot,
      )

    assert_not_equal first.id, second.id
    assert_not_equal first.identity_digest, second.identity_digest
    assert_not_equal first.recognized_deployment_key, second.recognized_deployment_key
  end

  private

    def create_runtime!
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: program.manifest_snapshot,
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent = deployment
      capability_snapshot = {
        "agent_capabilities_version" => "2026-03-13",
        "hostname" => "fixture-host",
        "container_id" => "container-#{SecureRandom.hex(4)}",
        "build_id" => "build-#{SecureRandom.hex(4)}",
      }
      initialize_result = {
        "identity" => {
          "agent_key" => "fixture-program",
          "deployment_fingerprint" => deployment.deployment_fingerprint,
          "protocol_version" => deployment.protocol_version,
          "agent_sdk_version" => deployment.agent_sdk_version,
          "supported_methods" => Agents::Protocol::REQUIRED_METHODS + ["attachments.import"],
        },
      }

      {
        agent: agent,
        capability_snapshot: capability_snapshot,
        deployment: deployment,
        initialize_result: initialize_result,
        program: program,
      }
    end
end
