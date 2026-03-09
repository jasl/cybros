require "test_helper"

class RunDraftApprovalResumeTest < ActiveSupport::TestCase
  test "approval park marks the agent node awaiting approval and resume finalizes without a second turn prepare" do
    prepare_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            prepare_calls << :called
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "target_switch",
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    assert_equal "awaiting_approval", draft.status
    assert_equal 1, prepare_calls.size
    assert_nil draft.materialized_conversation_run_id
    assert_equal DAG::Node::AWAITING_APPROVAL, agent_node.reload.state

    error =
      assert_raises(Cybros::Error) do
        conversation.start_pending_agent_node!(node_id: agent_node.id, claimed_by: "manual-start:test")
      end
    assert_equal "state_changed", error.message

    draft.update!(approval_state: draft.approval_state.merge("status" => "approved"))
    run = RunDrafts::ApprovalResumeService.resume!(draft: draft)

    assert_equal 1, prepare_calls.size
    assert_equal run.id, draft.reload.materialized_conversation_run_id
    assert_equal "finalized", draft.status
    assert_equal DAG::Node::PENDING, agent_node.reload.state
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
      target = create_execution_target!
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation }
    end

    def create_execution_target!
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
          root_path: "/tmp/approval-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: "Primary target",
        status: "active",
        sandboxed: true,
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
