require "test_helper"

class AgentExecutionCapacityTest < ActiveSupport::TestCase
  test "planning and finalization snapshot agent-scoped capacity without requiring a public execution target" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )
    run = RunDrafts::FinalizeService.finalize!(draft: draft)

    assert_equal draft.recognized_deployment_id, run.recognized_deployment_id
    assert_equal draft.recognized_deployment_key, run.recognized_deployment_key
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, draft.runtime_governors.dig("execution_capacity", "scope_id")
    assert_equal "agent", run.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, run.runtime_governors.dig("execution_capacity", "scope_id")
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {
            "agent_key" => "fixture-program",
            "name" => "Fixture Program",
          },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      target =
        create_execution_target!(
          max_concurrent_tasks: 2,
          max_queued_tasks: 5,
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
      conversation =
        create_conversation!(
          user: user,
          title: "Chat",
          agent: agent,
        )

      { agent: agent, conversation: conversation, deployment: deployment, program: program }
    end

    def create_execution_target!(max_concurrent_tasks:, max_queued_tasks:)
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: max_concurrent_tasks,
          max_queued_tasks: max_queued_tasks,
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
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      )
    end
end
