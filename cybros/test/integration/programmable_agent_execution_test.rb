require "test_helper"

class ProgrammableAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "programmable conversation runs execute through turn compose on the pinned deployment" do
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node_id =
      conversation.root_graph.nodes
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
        .id
    conversation.root_graph.nodes.find(agent_node_id).update!(claim_after_at: nil)
    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
    assert_includes claimed, agent_node_id

    DAG::Runner.run_node!(agent_node_id)

    agent =
      conversation.root_graph.nodes
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent.id)
    invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "turn.compose")
    session = invocation.last_session

    assert_equal DAG::Node::FINISHED, agent.reload.state
    assert_equal "fixture compose response", agent.body_output.fetch("content")
    assert_equal "succeeded", run.reload.state
    assert_equal "succeeded", invocation.status
    assert_not_nil session
    assert_equal "closed", session.status
  ensure
    server&.shutdown
  end

  test "programmable conversation runs invoke turn handle_error when turn compose fails" do
    handled_errors = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "turn.compose" => lambda do |_params, _base_result, _identity|
            raise StandardError, "compose exploded"
          end,
          "turn.handle_error" => lambda do |params, _base_result, _identity|
            handled_errors << params.fetch("error")
            {
              "output" => {
                "role" => "assistant",
                "content" => "fixture recovery response",
              },
            }
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node_id =
      conversation.root_graph.nodes
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
        .id
    conversation.root_graph.nodes.find(agent_node_id).update!(claim_after_at: nil)
    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
    assert_includes claimed, agent_node_id

    DAG::Runner.run_node!(agent_node_id)

    agent =
      conversation.root_graph.nodes
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent.id)
    compose_invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "turn.compose")
    handle_error_invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "turn.handle_error")

    assert_equal DAG::Node::FINISHED, agent.reload.state
    assert_equal "fixture recovery response", agent.body_output.fetch("content")
    assert_equal "succeeded", run.reload.state
    assert_equal "failed", compose_invocation.status
    assert_equal "succeeded", handle_error_invocation.status
    assert handled_errors.dig(0, "class").present?
    assert_includes handled_errors.dig(0, "message"), "compose exploded"
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      program =
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
      deployment =
        AgentDeployment.create!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: AgentDeployments::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      credential = LLMProviderCredential.find_or_initialize_by(provider_key: "openai", status: "active")
      credential.assign_attributes(
        credential_type: "api_key",
        api_key: "sk-test",
        max_concurrent_requests: 3,
        requests_per_minute: 90,
        tokens_per_minute: 180_000,
        burst_limit: 6,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      )
      credential.save!
      location =
        ExecutionLocation.create!(
          name: "Primary host",
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
        Workspace.create!(
          execution_location: location,
          name: "Primary workspace",
          root_path: "/tmp/programmable-exec-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: "Primary target",
          status: "active",
          sandboxed: true,
        )

      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation, deployment: deployment, program: program }
    end
end
