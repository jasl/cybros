require "test_helper"

class RunDraftTargetSwitchTest < ActiveSupport::TestCase
  test "accepted target switch re-resolves draft governors and finalizes the new target into the run snapshot" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    alternate_target =
      create_execution_target!(
        name: "Alternate target",
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 5,
        default_timeout_s_override: 600,
      )
    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Switch target",
        },
      )

    result = AgentRpc::KernelServices::ExecutionTargets.propose!(draft: draft, execution_target_id: alternate_target.id)
    run = RunDrafts::FinalizeService.finalize!(draft: draft)

    assert_equal "allow", result.dig("switch_decision", "decision")
    assert_equal alternate_target.id, draft.reload.proposed_execution_target_id
    assert_equal alternate_target.id, run.execution_target_id
    assert_equal "execution_target", run.runtime_governors.dig("execution_quota", "scope_type")
    assert_equal 2, run.runtime_governors.dig("execution_quota", "max_concurrent_tasks")
    assert_equal alternate_target.id, conversation.reload.default_execution_target_id
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      program = AgentProgram.create!(
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
        deployment_fingerprint: "deployment:v1",
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
      target = create_execution_target!(name: "Primary target")
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "full_access",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation }
    end

    def create_execution_target!(name:, max_concurrent_tasks_override: nil, max_queued_tasks_override: nil, default_timeout_s_override: nil)
      location =
        ExecutionLocation.create!(
          name: "#{name} host",
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
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: name,
        status: "active",
        sandboxed: true,
        max_concurrent_tasks_override: max_concurrent_tasks_override,
        max_queued_tasks_override: max_queued_tasks_override,
        default_timeout_s_override: default_timeout_s_override,
      )
    end

    def ensure_active_openai_credential!
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
      credential
    end
end
