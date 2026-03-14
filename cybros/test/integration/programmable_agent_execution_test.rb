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
      agent = materialize_agent_runtime!(program: program)
      fixture_identity = Cybros::ProgrammableAgentFixture.identity
      supported_methods = fixture_identity.fetch("supported_methods")
      deployment =
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: fixture_identity.fetch("deployment_fingerprint"),
          status: "active",
          health_status: "healthy",
          protocol_version: fixture_identity.fetch("protocol_version"),
          agent_sdk_version: fixture_identity.fetch("agent_sdk_version"),
          supported_methods: supported_methods,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {
            "observed_runtime_identity" => {
              "supported_methods" => supported_methods,
            },
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)

      conversation =
        create_conversation!(
          user: user,
          title: "Chat",
          agent: agent,
        )
      conversation.update!(
        permission_mode: "default",
        agent_config_schema_fingerprint: agent.config_schema_fingerprint,
      )

      {
        agent: agent,
        conversation: conversation,
        deployment: deployment,
        program: program,
        recognized_deployment: recognized_deployment,
      }
    end
end
