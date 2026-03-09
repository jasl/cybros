require "application_system_test_case"

class SystemSettingsAutomationsSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "operator can browse scheduled automation history" do
    owner = create_user!(email: "owner@example.com")
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(user: owner, endpoint_url: server.rpc_url, permission_mode: "full_access")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)

    perform_enqueued_jobs only: Automations::ExecuteRunJob do
      dispatch_due_automation!(automation: runtime.fetch(:automation), now: scheduled_for)
    end

    sign_in_as!(email: owner.identity.email)
    visit system_settings_automations_path

    assert_text "Automations"
    assert_text runtime.fetch(:automation).task_payload.fetch("prompt")
    assert_text runtime.fetch(:program).name
    assert_text runtime.fetch(:target).name

    within("tr", text: runtime.fetch(:automation).task_payload.fetch("prompt")) do
      click_link "View"
    end

    assert_current_path system_settings_automation_path(runtime.fetch(:automation))
    assert_text "completed"
    assert_text scheduled_for.iso8601
    assert_text "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
  ensure
    server&.shutdown
  end

  test "operator can approve a parked automation run from the browser surface" do
    owner = create_user!(email: "approver@example.com")
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
    runtime = create_automation_runtime!(user: owner, endpoint_url: server.rpc_url, permission_mode: "default")
    automation_run = nil

    perform_enqueued_jobs only: Automations::ExecuteRunJob do
      automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))
    end

    sign_in_as!(email: owner.identity.email)
    visit system_settings_automation_path(runtime.fetch(:automation))

    assert_text "awaiting_approval"
    assert_text "pending_confirmation"

    within("tbody tr", text: "awaiting_approval") do
      click_button "Approve"
    end

    assert_current_path system_settings_automation_path(runtime.fetch(:automation))
    assert_text "Automation run approved."
    assert_text "completed"
    assert_text "approved"
  ensure
    server&.shutdown
  end

  private

    def create_automation_runtime!(user:, endpoint_url:, permission_mode:)
      program = create_program!
      active_deployment!(program: program, endpoint_url: endpoint_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Operator automation target")
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
            "prompt" => "Nightly automation",
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

    def dispatch_due_automation!(automation:, now:)
      runs = Automations::Scheduler.dispatch_due!(now: now)
      matching_run = runs.find { |run| run.automation_id == automation.id }

      assert_not_nil matching_run

      matching_run
    end

    def create_program!
      AgentProgram.create!(
        name: "Operator Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Operator Fixture Program",
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
