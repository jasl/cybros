require "test_helper"

class AutomationManualApprovalTest < ActiveSupport::TestCase
  test "automation approval parking records awaiting approval audit on the automation run" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "fixture_approval",
              },
            )
          end,
        },
      ).start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "default")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    result = Automations::RunOrchestrator.start!(automation_run: automation_run)

    draft = result.fetch(:draft)
    automation_run.reload

    assert_equal "awaiting_approval", draft.status
    assert_nil result.fetch(:conversation_run)
    assert_equal "awaiting_approval", automation_run.status
    assert_equal "pending_confirmation", automation_run.approval_state.fetch("status")
    assert_equal "fixture_approval", automation_run.approval_state.fetch("reason")
    assert_equal draft.id, automation_run.snapshot.dig("draft", "id")
    assert_equal "pending_confirmation", automation_run.snapshot.dig("draft", "approval_state", "status")
  ensure
    server&.shutdown
  end

  test "approved parked automation run records approval and completion" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "fixture_approval",
              },
            )
          end,
        },
      ).start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "default")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    result = Automations::RunOrchestrator.start!(automation_run: automation_run)
    draft = result.fetch(:draft)
    draft.update!(
      approval_state: draft.approval_state.merge("status" => "approved", "approved_at" => Time.current.iso8601),
    )

    resumed = RunDrafts::ApprovalResumeService.resume!(draft: draft)
    automation_run.reload

    assert_nil resumed
    assert_equal "finalized", draft.reload.status
    assert_equal "completed", automation_run.status
    assert_equal "approved", automation_run.approval_state.fetch("status")
    assert_equal "approved", automation_run.snapshot.dig("draft", "approval_state", "status")
    assert_nil automation_run.conversation_run_id
  ensure
    server&.shutdown
  end

  test "rejected parked automation run records rejection without materializing a conversation run" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "fixture_approval",
              },
            )
          end,
        },
      ).start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "default")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    result = Automations::RunOrchestrator.start!(automation_run: automation_run)
    draft = result.fetch(:draft)
    draft.update!(
      approval_state: draft.approval_state.merge("status" => "rejected", "reason" => "operator_denied"),
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }
    automation_run.reload

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal "discarded", draft.reload.status
    assert_equal "rejected", automation_run.status
    assert_equal "rejected", automation_run.approval_state.fetch("status")
    assert_equal "operator_denied", automation_run.approval_state.fetch("reason")
    assert_equal "rejected", automation_run.snapshot.dig("draft", "approval_state", "status")
    assert_nil automation_run.conversation_run_id
  ensure
    server&.shutdown
  end

  private

    def create_automation_runtime!(endpoint_url:, permission_mode:)
      user = create_user!
      program = create_program!
      active_deployment!(program: program, endpoint_url: endpoint_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Automation target")
      ensure_active_openai_credential!
      automation =
        Automation.create!(
          user: user,
          agent_program: program,
          execution_target: target,
          permission_mode: permission_mode,
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

      { automation: automation, program: program, target: target }
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
