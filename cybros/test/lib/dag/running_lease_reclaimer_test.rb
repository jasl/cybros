require "test_helper"

class DAG::RunningLeaseReclaimerTest < ActiveSupport::TestCase
  test "reclaim! marks expired running nodes as errored" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::RUNNING,
      lease_expires_at: 1.minute.ago,
      metadata: {}
    )

    reclaimed = DAG::RunningLeaseReclaimer.reclaim!(graph: graph, now: Time.current)
    assert_equal [node.id], reclaimed

    node.reload
    assert_equal DAG::Node::ERRORED, node.state
    assert_equal "running_lease_expired", node.metadata.fetch("error")
    assert node.finished_at.present?

    assert conversation.events.exists?(
      event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
      subject: node
    )
  end

  test "reclaim! marks governed conversation runs failed and releases execution capacity" do
    execution = create_governed_running_execution!

    reclaimed = DAG::RunningLeaseReclaimer.reclaim!(graph: execution.fetch(:conversation).dag_graph, now: Time.current)

    assert_equal [execution.fetch(:node).id], reclaimed
    assert_equal "failed", execution.fetch(:run).reload.state
    assert_equal "released", execution.fetch(:lease).reload.status
    assert_includes execution.fetch(:run).error.fetch("message"), "running_lease_expired"
  end

  private

    def create_governed_running_execution!
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        )
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "websocket",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
          status: "active",
          health_status: "healthy",
          activated_at: Time.current.change(usec: 0),
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
        )
      credential =
        LLMProviderCredential.create!(
          provider_key: "openai-#{SecureRandom.hex(4)}",
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        )
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 1,
          max_queued_tasks: 2,
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
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Fixture target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      conversation =
        create_conversation!(
          agent: agent,
          agent_program: program,
          default_execution_target: nil,
        )
      graph = conversation.dag_graph
      node =
        graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          claimed_at: 1.minute.ago,
          lease_expires_at: 1.minute.ago,
          metadata: {},
        )

      capacity_snapshot = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent)

      run =
        ConversationRun.create!(
          build_conversation_run_attributes(
            conversation: conversation,
            dag_node_id: node.id,
            agent: agent,
            recognized_deployment: recognized_deployment,
            state: "running",
            queued_at: 2.minutes.ago.change(usec: 0),
            started_at: 1.minute.ago.change(usec: 0),
            provider_credential: credential,
            selected_model_ref: "openai/gpt-5.4",
            effective_public_settings: {},
            effective_agent_config: {},
            agent_config_schema_fingerprint: program.config_schema_fingerprint,
            effective_policy: {},
            runtime_governors: {
              "provider_limiter" => provider_limiter_snapshot(
                provider_credential: credential,
                selected_model_ref: "openai/gpt-5.4",
              ),
              "execution_capacity" => capacity_snapshot,
            },
            snapshot: { "execution_target_id" => target.id },
          ),
        )

      lease =
        ExecutionCapacityLease.create!(
          subject_type: capacity_snapshot.fetch("scope_type"),
          subject_id: capacity_snapshot.fetch("scope_id"),
          execution_request_id: "conversation_run:#{run.id}",
          holder_type: "ConversationRun",
          holder_id: run.id.to_s,
          slots: 1,
          lease_expires_at: 5.minutes.from_now,
          heartbeat_at: Time.current,
          status: "active",
          recovery_metadata: {},
        )

      { conversation: conversation, node: node, run: run, lease: lease }
    end
end
