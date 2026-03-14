require "test_helper"

class RecognizedDeploymentTest < ActiveSupport::TestCase
  test "deduplicates identical runtime identities for the same agent" do
    runtime = create_runtime!

    first = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))
    second = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    assert_equal first.id, second.id
    assert_equal first.identity_digest, second.identity_digest
    assert_equal first.recognized_deployment_key, second.recognized_deployment_key
  end

  test "creates a new row when hard runtime identity changes" do
    runtime = create_runtime!
    first = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))
    runtime.fetch(:deployment).update!(
      deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
      capability_snapshot: runtime.fetch(:deployment).capability_snapshot.merge("build_id" => SecureRandom.hex(6)),
    )

    second = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))

    assert_not_equal first.id, second.id
    assert_not_equal first.identity_digest, second.identity_digest
    assert_not_equal first.recognized_deployment_key, second.recognized_deployment_key
  end

  test "recognized deployment keys remain unique across agents with the same runtime identity" do
    runtime = create_runtime!
    other_runtime = create_runtime!
    shared_fingerprint = "deployment:shared-runtime"
    shared_capability_snapshot = { "agent_capabilities_version" => "2026-03-13" }

    runtime.fetch(:deployment).update!(
      deployment_fingerprint: shared_fingerprint,
      capability_snapshot: shared_capability_snapshot,
    )
    other_runtime.fetch(:deployment).update!(
      deployment_fingerprint: shared_fingerprint,
      capability_snapshot: shared_capability_snapshot,
    )

    first = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))
    second = RecognizedDeployment.recognize!(agent: other_runtime.fetch(:agent), deployment: other_runtime.fetch(:deployment))

    assert_equal first.identity_digest, second.identity_digest
    assert_not_equal first.agent_id, second.agent_id
    assert_not_equal first.recognized_deployment_key, second.recognized_deployment_key
  end

  test "identity digests stay stable across equivalent hash key ordering" do
    first_payload = {
      "deployment_fingerprint" => "deployment:stable",
      "protocol_version" => "agent_rpc.v1",
      "capability_snapshot_digest" => {
        "z" => 1,
        "nested" => { "b" => 2, "a" => 1 },
      },
      "supported_methods" => ["initialize", "before_agent_step"],
    }
    second_payload = {
      "supported_methods" => ["initialize", "before_agent_step"],
      "capability_snapshot_digest" => {
        "nested" => { "a" => 1, "b" => 2 },
        "z" => 1,
      },
      "protocol_version" => "agent_rpc.v1",
      "deployment_fingerprint" => "deployment:stable",
    }

    assert_equal RecognizedDeployment.digest_for(first_payload), RecognizedDeployment.digest_for(second_payload)
  end

  test "retire clears sensitive debug fields without invalidating historical rows" do
    runtime = create_runtime!
    recognized = RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))
    run =
      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: create_conversation!(agent: runtime.fetch(:agent), agent_program: runtime.fetch(:program), default_execution_target: runtime.fetch(:target)),
          dag_node_id: SecureRandom.uuid,
          agent: runtime.fetch(:agent),
          recognized_deployment: recognized,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          effective_permission_mode: "default",
          agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
          runtime_governors: runtime_governors_snapshot(agent: runtime.fetch(:agent)),
          snapshot: {},
        ),
      )

    recognized.retire!

    assert_predicate recognized.reload, :retired?
    assert_nil recognized.hostname
    assert_nil recognized.container_id
    assert_equal recognized.recognized_deployment_key, run.reload.recognized_deployment_key
  end

  private

    def create_runtime!
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = create_execution_target!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS + ["attachments.import"],
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {
            "agent_capabilities_version" => "2026-03-13",
            "hostname" => "fixture-host",
            "container_id" => "container-#{SecureRandom.hex(4)}",
            "build_id" => "build-#{SecureRandom.hex(4)}",
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)

      {
        agent: agent,
        deployment: deployment,
        program: program,
        target: target,
      }
    end

    def create_execution_target!
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Fixture workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        execution_location: location,
        workspace: workspace,
        name: "Fixture target #{SecureRandom.hex(4)}",
        status: "active",
        sandboxed: true,
      )
    end
end
