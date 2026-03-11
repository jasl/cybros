require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class ProgrammableAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "programmable conversation runs finalize through before_finalize_output on the pinned deployment" do
    observed_payloads = []
    llm_server = MockLLMServer.new do |_payload|
      MockLLMServer.chat_response(content: "llm draft answer")
    end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_finalize_output" => lambda do |params, _base_result, _identity|
            observed_payloads << params.deep_dup
            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "fixture finalized response",
                  },
                },
              ],
            }
          end,
        },
      ).start
    runtime = nil
    conversation = nil

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server:)
      conversation = runtime.fetch(:conversation)

      conversation.append_user_message!(content: "Ship it", model_ref: "dev/mock-model")
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
      invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")
      session = invocation.last_session

      assert_equal DAG::Node::FINISHED, agent.reload.state
      assert_equal "fixture finalized response", agent.body_output.fetch("content")
      assert_equal "succeeded", run.reload.state
      assert_equal "succeeded", invocation.status
      assert_not_nil session
      assert_equal "closed", session.status
      assert_equal "llm draft answer", observed_payloads.dig(0, "draft_output", "content")
      assert_equal "dev/mock-model", observed_payloads.dig(0, "selected_model_ref")
      assert_equal ["before_finalize_output"], AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id).order(:created_at).pluck(:method)
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "programmable conversation runs invoke after_task_notice when the llm provider fails" do
    handled_errors = []
    llm_server = MockLLMServer.new do |_payload|
      MockLLMServer.error_response(status: 500, message: "llm exploded")
    end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "after_task_notice" => lambda do |params, _base_result, _identity|
            handled_errors << params.fetch("task_notice")
            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "fixture recovery response",
                  },
                },
              ],
            }
          end,
        },
      ).start
    runtime = nil
    conversation = nil

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server:)
      conversation = runtime.fetch(:conversation)

      conversation.append_user_message!(content: "Ship it", model_ref: "dev/mock-model")
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
      error_invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "after_task_notice")

      assert_equal DAG::Node::FINISHED, agent.reload.state
      assert_equal "fixture recovery response", agent.body_output.fetch("content")
      assert_equal "succeeded", run.reload.state
      assert_equal "succeeded", error_invocation.status
      assert_equal "provider_error", handled_errors.dig(0, "notice", "kind")
      assert handled_errors.dig(0, "error", "class").present?
      assert_includes handled_errors.dig(0, "error", "message"), "llm exploded"
      assert_equal ["after_task_notice"], AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id).order(:created_at).pluck(:method)
    end
  ensure
    llm_server&.shutdown
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
          supported_methods: AgentDeployments::REQUIRED_METHODS + %w[before_finalize_output after_task_notice],
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
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
