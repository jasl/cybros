require "test_helper"

class RuntimeGovernance::RuntimeWaitsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "parks waits idempotently for the same owner and governed subject" do
    parked =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RunDraft",
        owner_id: "draft-1",
        reason_type: "provider_limit",
        subject_type: "llm_provider_credential",
        subject_id: SecureRandom.uuid,
        retry_at: 1.minute.from_now,
        details: { "provider_request_id" => "provider-req-1" },
      )

    duplicate =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RunDraft",
        owner_id: "draft-1",
        reason_type: "provider_limit",
        subject_type: parked.subject_type,
        subject_id: parked.subject_id,
        retry_at: 2.minutes.from_now,
        details: { "provider_request_id" => "provider-req-1" },
      )

    assert_equal parked.id, duplicate.id
    assert_equal(
      1,
      RuntimeWait.where(
        owner_type: "RunDraft",
        owner_id: "draft-1",
        reason_type: "provider_limit",
        subject_type: parked.subject_type,
        subject_id: parked.subject_id,
      ).count,
    )
  end

  test "returns the oldest ready wait first within one reason and subject" do
    subject_id = SecureRandom.uuid
    now = Time.current.change(usec: 0)
    newer =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: "run-2",
        reason_type: "execution_capacity",
        subject_type: "execution_location",
        subject_id: subject_id,
        retry_at: now,
        details: {},
        now: now + 5.seconds,
      )
    older =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: "run-1",
        reason_type: "execution_capacity",
        subject_type: "execution_location",
        subject_id: subject_id,
        retry_at: now,
        details: {},
        now: now,
      )
    RuntimeGovernance::RuntimeWaits.park!(
      owner_type: "ConversationRun",
      owner_id: "run-3",
      reason_type: "execution_capacity",
      subject_type: "execution_location",
      subject_id: subject_id,
      retry_at: now + 5.minutes,
      details: {},
      now: now + 10.seconds,
    )

    ready =
      RuntimeGovernance::RuntimeWaits.next_ready(
        reason_type: "execution_capacity",
        subject_type: "execution_location",
        subject_id: subject_id,
        now: now + 30.seconds,
      )

    assert_equal older.id, ready.id
    refute_equal newer.id, ready.id
  end

  test "resumes parked waits and accepts deployment_backoff as a durable wait reason" do
    wait =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "AgentDeployment",
        owner_id: SecureRandom.uuid,
        reason_type: "deployment_backoff",
        subject_type: "agent_deployment",
        subject_id: SecureRandom.uuid,
        retry_at: 1.minute.from_now,
        details: { "attempt" => 2 },
      )

    resumed = RuntimeGovernance::RuntimeWaits.resume!(wait: wait)

    assert_equal "resumed", resumed.status
  end

  test "resuming an execution-capacity wait clears node retry gating and kicks the bound graph" do
    execution = create_waiting_execution!
    wait =
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: execution.fetch(:run).id,
        reason_type: "execution_capacity",
        subject_type: "execution_target",
        subject_id: execution.fetch(:run).execution_target_id,
        retry_at: 5.minutes.from_now.change(usec: 0),
        details: { "execution_request_id" => "conversation_run:#{execution.fetch(:run).id}" },
      )

    execution.fetch(:node).update!(
      claim_after_at: wait.retry_at,
      metadata: {
        "runtime_wait" => {
          "reason_type" => wait.reason_type,
          "runtime_wait_id" => wait.id,
          "retry_at" => wait.retry_at.iso8601(6),
          "details" => wait.details,
        },
      },
    )

    resumed = nil

    assert_enqueued_with(job: DAG::TickGraphJob, args: [execution.fetch(:conversation).dag_graph.id, { limit: 10 }]) do
      resumed = RuntimeGovernance::RuntimeWaits.resume!(wait: wait)
    end

    assert_equal "resumed", resumed.status
    assert_nil execution.fetch(:node).reload.claim_after_at
    assert_nil execution.fetch(:node).metadata["runtime_wait"]
  end

  private

    def create_waiting_execution!
      conversation = create_conversation!
      graph = conversation.dag_graph
      user = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
      node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      graph.edges.create!(from_node_id: user.id, to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)

      program =
        AgentProgram.create!(
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
        AgentDeployment.create!(
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
          supported_methods: %w[initialize turn.prepare turn.compose],
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
        ExecutionLocation.create!(
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
        Workspace.create!(
          execution_location: location,
          name: "Fixture workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: "Fixture target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )

      run =
        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: node.id,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          agent_program: program,
          contract_fingerprint: program.published_contract_fingerprint,
          agent_deployment: deployment,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
          provider_credential: credential,
          execution_target: target,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: program.config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: {},
          snapshot: { "execution_target_id" => target.id },
        )

      { conversation: conversation, node: node, run: run }
    end
end
