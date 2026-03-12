require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class ProgrammableAgentToolRoutingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "planning-owned tool surface materializes agent-priority routed tool tasks without compose-owned manifest metadata" do
    captured_tools = nil
    captured_request = nil
    observed_planning_payload = nil
    llm_server =
      MockLLMServer.new do |payload|
        captured_request = payload
        captured_tools = payload["tools"]
        MockLLMServer.chat_response(
          content: "Need compaction",
          finish_reason: "tool_calls",
          tool_calls: [
            {
              "id" => "tc_1",
              "type" => "function",
              "function" => {
                "name" => "subagent_spawn",
                "arguments" => JSON.generate({ "name" => "Helper", "prompt" => "Summarize this" }),
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
                  "logical_tool_name" => "subagent_spawn",
                  "implementation_ref" => "agent://subagent_spawn",
                },
              ],
            }
          end,
          "before_agent_step" => lambda do |params, base_result, _identity|
            observed_planning_payload = params.deep_dup
            spawn_tool =
              Array(params.dig("capability_snapshot", "effective_tools")).find do |tool|
                tool.is_a?(Hash) && tool["logical_tool_name"].to_s == "subagent_spawn"
              end

            result = base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "agent_config_patch" => {
                    "llm_options" => {
                      "stream" => false,
                    },
                  },
                },
              },
            )
            result["planning"]["tool_surface"] = {
              "capability_registry_snapshot_id" => params.dig("capability_snapshot", "capability_registry_snapshot_id"),
              "selected_tool_ids" => [spawn_tool.fetch("effective_tool_id")],
              "tool_surface_label" => "fixture-agent-priority",
            }
            result
          end,
        },
      ).start
    program = create_program!
    deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
    Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
    deployment.reload

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      conversation = create_programmable_conversation!(program: program, llm_options: { "stream" => false })
      result = conversation.append_user_message!(content: "Compact this", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      agent_node.update!(claim_after_at: nil)

      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      snapshot = Cybros::ProgrammableAgent::CapabilitySnapshot.restore(deployment.capability_snapshot)
      route = snapshot.route_for!("subagent_spawn")
      turn_tasks =
        conversation.root_graph.nodes
          .where(node_type: Messages::Task.node_type_key, turn_id: agent_node.turn_id)
          .order(:id)
          .to_a
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)
      finalize_invocation = AgentRPCInvocation.find_by(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")
      task =
        turn_tasks.find do |node|
          node.idempotency_key == "agent_core.tool:#{agent_node.id}:tc_1"
        end

      assert task,
        "expected routed tool task for tc_1, got tasks=#{turn_tasks.map { |node| { id: node.id, state: node.state, idempotency_key: node.idempotency_key, body_input: node.body_input } }}, " \
        "agent_output=#{agent_node.reload.body_output}, finalize_status=#{finalize_invocation&.status}, run_agent_config=#{run.effective_agent_config.inspect}, " \
        "llm_request=#{captured_request.inspect}"

      assert_equal ["subagent_spawn"], Array(captured_tools).map { |tool| tool_name_for(tool) }
      assert_equal deployment.capability_snapshot.fetch("capability_registry_snapshot_id"), observed_planning_payload.dig("capability_snapshot", "capability_registry_snapshot_id")
      assert_equal "subagent_spawn", task.body_input.fetch("requested_name")
      assert_equal "subagent_spawn", task.body_input.fetch("logical_tool_name")
      assert_equal route.effective_tool_id, task.body_input.fetch("effective_tool_id")
      assert_equal "agent_program", task.body_input.fetch("implementation_source")
      assert_equal "agent://subagent_spawn", task.body_input.fetch("implementation_ref")
      assert_equal deployment.capability_snapshot.fetch("capability_registry_snapshot_id"), task.body_input.fetch("capability_registry_snapshot_id")
      assert_match(/\Asurface_/, task.body_input.fetch("tool_surface_id"))
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "runtime pins capability snapshot authority on the conversation run even if the deployment snapshot changes later" do
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(
          content: "Need delegated help",
          finish_reason: "tool_calls",
          tool_calls: [
            {
              "id" => "tc_pinned",
              "type" => "function",
              "function" => {
                "name" => "subagent_spawn",
                "arguments" => JSON.generate({ "name" => "Helper", "prompt" => "Summarize this" }),
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
                  "logical_tool_name" => "subagent_spawn",
                  "implementation_ref" => "agent://subagent_spawn",
                },
              ],
            }
          end,
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "agent_config_patch" => {
                    "llm_options" => {
                      "stream" => false,
                    },
                  },
                },
              },
            )
          end,
        },
      ).start
    program = create_program!
    deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
    Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
    deployment.reload

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      conversation = create_programmable_conversation!(program: program, llm_options: { "stream" => false })
      result = conversation.append_user_message!(content: "Compact this", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      agent_node.update!(claim_after_at: nil)

      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)
      pinned_snapshot_id = run.snapshot.dig("capability_snapshot", "capability_registry_snapshot_id")

      deployment.update!(
        capability_snapshot: deployment.capability_snapshot.deep_merge(
          "capability_registry_snapshot_id" => "csnap_mutated_after_finalize"
        ),
      )

      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      task =
        conversation.root_graph.nodes
          .where(node_type: Messages::Task.node_type_key, turn_id: agent_node.turn_id)
          .order(:id)
          .find { |node| node.idempotency_key == "agent_core.tool:#{agent_node.id}:tc_pinned" }

      assert_equal pinned_snapshot_id, task.body_input.fetch("capability_registry_snapshot_id")
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  private

    def create_program!
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
    end

    def create_active_deployment!(program:, endpoint_url:)
      AgentDeployment.create!(
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
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_programmable_conversation!(program:, llm_options: nil)
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
          root_path: "/tmp/programmable-routing-#{SecureRandom.hex(4)}",
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

      conversation = create_conversation!(title: "Programmable routing")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
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

  private

    def tool_name_for(tool)
      return "" unless tool.is_a?(Hash)

      tool["name"].to_s.presence || tool.dig("function", "name").to_s
    end
end
