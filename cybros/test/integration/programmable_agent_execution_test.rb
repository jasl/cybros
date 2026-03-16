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

  test "direct tool calls keep the shared continuation agent node behind queued work" do
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(
          content: "Need repo search",
          finish_reason: "tool_calls",
          tool_calls: [
            {
              "id" => "tc_search",
              "type" => "function",
              "function" => {
                "name" => "search",
                "arguments" => JSON.generate({ "query" => "TODO" }),
              },
            },
          ],
        )
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "capabilities.handshake" => lambda do |_params, _base_result, _identity|
            {
              "status" => "refreshed",
              "agent_capabilities_version" => "fixture-agent-capabilities:v2",
              "agent_tool_catalog" => [
                {
                  "logical_tool_name" => "search",
                  "implementation_ref" => "agent://search",
                },
              ],
            }
          end,
        },
      ).start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      program = create_program!
      deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
      Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
      deployment.reload
      conversation = create_programmable_conversation!(program: program, llm_options: { "stream" => false })

      result = conversation.append_user_message!(content: "Search the repo", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      agent_node.update!(claim_after_at: nil)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      queued =
        conversation.turn_internal_tasks
          .where(turn_id: agent_node.turn_id, source_hook_name: "agent_message_tool_loop")
          .ordered
          .find { |row| row.input["tool_call_id"].to_s == "tc_search" }
      continuation =
        conversation.root_graph.nodes
          .where(node_type: Messages::AgentMessage.node_type_key, idempotency_key: "agent_core.next_from:#{agent_node.id}")
          .order(:id)
          .first

      assert queued
      assert continuation
      assert_equal DAG::Node::PENDING, continuation.state
      refute conversation.root_graph.nodes.where(node_type: Messages::Task.node_type_key, turn_id: agent_node.turn_id)
        .exists?(idempotency_key: "agent_core.tool:#{agent_node.id}:tc_search")

      materialize_until_row!(graph: conversation.root_graph, row: queued)

      materialized_task = conversation.root_graph.nodes.find(queued.reload.materialized_task_node_id)

      assert conversation.root_graph.edges.active.exists?(
        from_node_id: materialized_task.id,
        to_node_id: continuation.id,
        edge_type: DAG::Edge::SEQUENCE,
      )
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
      Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
      deployment.reload
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

    def create_active_deployment!(program:, endpoint_url:)
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_programmable_conversation!(program:, llm_options: nil)
      location =
        create_execution_location_profile!(
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
        create_workspace_profile!(
          execution_location: location,
          name: "Primary workspace",
          root_path: "/tmp/programmable-execution-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Primary target",
          status: "active",
          sandboxed: true,
        )

      conversation = create_conversation!(title: "Programmable execution")
      agent = create_agent_runtime!(program: program, execution_target: target)
      conversation.update!(
        agent: agent,
        permission_mode: "default",
        agent_config: {
          program.config_namespace => {
            "llm_options" => llm_options || {},
          },
        },
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )
      conversation
    end

    def materialize_until_row!(graph:, row:, max_rounds: 6)
      max_rounds.times do
        TurnInternalTasks::Materializer.materialize_ready!(graph: graph)
        row.reload
        return row if row.materialized_task_node_id.present?

        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        break if claimed.empty?

        perform_enqueued_jobs do
          claimed.each { |node| DAG::Runner.run_node!(node.id) }
        end
      end

      row.reload
      assert row.materialized_task_node_id.present?,
        "expected row #{row.id} to materialize, status=#{row.status}, queue=#{graph.turn_internal_tasks.where(turn_id: row.turn_id).ordered.map { |queued| { id: queued.id, hook: queued.source_hook_name, logical_tool_name: queued.logical_tool_name, status: queued.status, materialized_task_node_id: queued.materialized_task_node_id, queue_position: queued.queue_position } } }"
      row
    end
end
