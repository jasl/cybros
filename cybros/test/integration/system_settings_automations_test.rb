require "test_helper"

class SystemSettingsAutomationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "requires authentication" do
    get system_settings_automations_path

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_member!

    get system_settings_automations_path

    assert_response :forbidden
  end

  test "index and show expose automation bindings and scheduled run history" do
    sign_in_owner!
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "full_access")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)

    perform_enqueued_jobs only: Automations::ExecuteRunJob do
      dispatch_due_automation!(automation: runtime.fetch(:automation), now: scheduled_for)
    end

    get system_settings_automations_path

    assert_response :success
    assert_includes response.body, runtime.fetch(:automation).task_payload.fetch("prompt")
    assert_includes response.body, runtime.fetch(:program).name
    assert_includes response.body, runtime.fetch(:target).name
    assert_includes response.body, "full_access"

    get system_settings_automation_path(runtime.fetch(:automation))

    assert_response :success
    assert_includes response.body, runtime.fetch(:program).name
    assert_includes response.body, runtime.fetch(:target).name
    assert_includes response.body, "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
    assert_includes response.body, "UTC"
    assert_includes response.body, scheduled_for.iso8601
    assert_includes response.body, "completed"
  ensure
    server&.shutdown
  end

  test "show supports operator approval for parked automation runs" do
    sign_in_owner!
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
    automation_run = nil

    perform_enqueued_jobs only: Automations::ExecuteRunJob do
      automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)
    end

    get system_settings_automation_path(runtime.fetch(:automation))

    assert_response :success
    assert_includes response.body, "awaiting_approval"
    assert_includes response.body, "pending_confirmation"
    assert_includes response.body, "Approve"
    assert_includes response.body, "Reject"

    post approve_system_settings_automation_automation_run_path(runtime.fetch(:automation), automation_run)

    assert_redirected_to system_settings_automation_path(runtime.fetch(:automation))
    follow_redirect!

    automation_run.reload

    assert_equal "completed", automation_run.status
    assert_equal "approved", automation_run.approval_state.fetch("status")
    assert_includes response.body, "completed"
    assert_includes response.body, "approved"
  ensure
    server&.shutdown
  end

  private

    def sign_in_owner!
      identity =
        Identity.create!(
          email: "admin@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      User.create!(identity: identity, role: :owner)

      post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def sign_in_member!
      identity =
        Identity.create!(
          email: "member@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      User.create!(identity: identity, role: :member)

      post session_path, params: { email: "member@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_automation_runtime!(endpoint_url:, permission_mode:)
      user = create_user!
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
