require "test_helper"

class AutomationRunDraftFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "automation dispatch creates an execution conversation and snapshots runtime bindings at execution time" do
    seen_conversation_ids = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            seen_conversation_ids << params["conversation_id"]
            base_result
          end,
        },
      ).start
    runtime = create_automation_runtime!(server:)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    execution_conversation = nil

    runtime.fetch(:deployment).update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    replacement =
      active_deployment!(
        program: runtime.fetch(:program),
        endpoint_url: server.rpc_url,
        deployment_fingerprint: "fixture-deployment-v1",
      )

    perform_enqueued_jobs only: Automations::ExecuteConversationJob do
      execution_conversation = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)
    end

    execution_conversation.reload
    draft = execution_conversation.run_drafts.order(:created_at, :id).last
    conversation_run = draft.materialized_conversation_run

    assert_equal [execution_conversation.id], seen_conversation_ids
    assert_equal runtime.fetch(:automation).id, execution_conversation.automation_id
    assert_equal runtime.fetch(:automation).agent_program_id, execution_conversation.agent_program_id
    assert_equal runtime.fetch(:automation).execution_target_id, execution_conversation.default_execution_target_id
    assert_equal draft.conversation_id, execution_conversation.id
    assert_equal "finalized", draft.status
    assert_equal conversation_run.id, draft.materialized_conversation_run_id
    assert_equal replacement.id, draft.agent_deployment_id
    assert_equal replacement.id, conversation_run.agent_deployment_id
    assert_equal runtime.fetch(:target).id, conversation_run.execution_target_id
    assert_equal "full_access", conversation_run.effective_permission_mode
    assert_equal draft.id, conversation_run.snapshot.dig("draft", "id")
    assert_equal scheduled_for.iso8601, execution_conversation.metadata.dig("schedule", "scheduled_for")
    assert_equal "running", execution_conversation.metadata.dig("automation_execution", "status")
    assert_equal conversation_run.id, execution_conversation.metadata.dig("automation_execution", "conversation_run_id")
  ensure
    server&.shutdown
  end

  private

    def create_automation_runtime!(server:)
      user = create_user!
      program = create_program!
      deployment = active_deployment!(program: program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Automation target")
      ensure_active_openai_credential!
      automation =
        Automation.create!(
          user: user,
          agent_program: program,
          execution_target: target,
          permission_mode: "full_access",
          status: "active",
          schedule_kind: "rrule",
          schedule_rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
          schedule_timezone: "UTC",
          task_payload: {
            "kind" => "scheduled_prompt",
            "prompt" => "Ship it",
            "selected_model_ref" => "openai/gpt-5.4",
          },
        )

      { automation: automation, program: program, deployment: deployment, target: target }
    end

    def dispatch_automation!(automation:, scheduled_for:)
      Automations::Dispatch.call!(
        automation: automation,
        scheduled_for: scheduled_for,
        dispatch_key: "#{automation.id}:#{scheduled_for.iso8601}",
        trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
      )
    end

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

    def active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
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

    def create_execution_target!(name:)
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
