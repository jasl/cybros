require "test_helper"
require_relative "../../support/programmable_agent_runtime_test_support"

class DAG::ProgrammableAgentStepStatusPlaceholderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "planning status updates the placeholder and final output reuses the same assistant node" do
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "fixture compose response")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Processing fixture plan",
                  "state" => "running",
                },
              ],
            )
          end,
        },
      ).start
    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server:)
      conversation = runtime.fetch(:conversation)

      result = conversation.append_user_message!(content: "Ship it", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node).reload

      assert_equal DAG::Node::PENDING, agent_node.state
      assert_equal "Processing fixture plan", agent_node.body_output_preview.fetch("content")

      preview_message = conversation.message_for_node_id(node_id: agent_node.id, mode: :full)
      assert_equal "Processing fixture plan", preview_message.dig("payload", "output_preview", "content")

      conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      final_node = conversation.root_graph.nodes.find(agent_node.id)
      transcript = conversation.root_graph.transcript_for(final_node.id)
      assistant_messages = transcript.select { |node| node.fetch("node_type") == Messages::AgentMessage.node_type_key }

      assert_equal DAG::Node::FINISHED, final_node.state
      assert_equal "fixture compose response", final_node.body_output.fetch("content")
      assert_equal [agent_node.id], assistant_messages.map { |node| node.fetch("node_id") }
      assert_equal "fixture compose response", assistant_messages.sole.dig("payload", "output_preview", "content")
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
      ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")
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
          root_path: "/tmp/programmable-step-status-#{SecureRandom.hex(4)}",
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

      { conversation: conversation, program: program }
    end
end
