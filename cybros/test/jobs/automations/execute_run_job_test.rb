require "test_helper"

class Automations::ExecuteRunJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  test "perform starts queued runs through the orchestrator" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))

    Automations::ExecuteRunJob.perform_now(automation_run.id)

    assert_equal "completed", automation_run.reload.status
  ensure
    server&.shutdown
  end

  test "perform ignores runs that are no longer queued" do
    automation_run = create_completed_run!

    assert_no_difference -> { RunDraft.count } do
      Automations::ExecuteRunJob.perform_now(automation_run.id)
    end

    assert_equal "completed", automation_run.reload.status
  end

  test "perform claims queued runs before orchestration so duplicate delivery is ignored" do
    automation_run = create_queued_run!
    start_calls = 0
    orchestrator_singleton = Automations::RunOrchestrator.singleton_class

    orchestrator_singleton.alias_method :__execute_run_job_test_original_start__, :start!
    orchestrator_singleton.define_method(:start!) do |automation_run:, **|
      start_calls += 1
      automation_run
    end

    begin
      Automations::ExecuteRunJob.perform_now(automation_run.id)
      Automations::ExecuteRunJob.perform_now(automation_run.id)
    ensure
      orchestrator_singleton.alias_method :start!, :__execute_run_job_test_original_start__
      orchestrator_singleton.remove_method :__execute_run_job_test_original_start__
    end

    assert_equal 1, start_calls
    assert_equal "running", automation_run.reload.status
  end

  test "perform marks the run failed if orchestration raises a non-standard exception after claim" do
    automation_run = create_queued_run!
    crash_class = Class.new(Exception)
    orchestrator_singleton = Automations::RunOrchestrator.singleton_class

    orchestrator_singleton.alias_method :__execute_run_job_test_original_start__, :start!
    orchestrator_singleton.define_method(:start!) do |**|
      raise crash_class, "hard crash"
    end

    error =
      begin
        assert_raises(crash_class) { Automations::ExecuteRunJob.perform_now(automation_run.id) }
      ensure
        orchestrator_singleton.alias_method :start!, :__execute_run_job_test_original_start__
        orchestrator_singleton.remove_method :__execute_run_job_test_original_start__
      end

    assert_equal "hard crash", error.message
    assert_equal "failed", automation_run.reload.status
    assert_equal "hard crash", automation_run.snapshot.dig("failure", "message")
  end

  private

    def create_automation_runtime!(endpoint_url:)
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

    def create_completed_run!
      automation = create_automation_runtime!(endpoint_url: "http://127.0.0.1:4319/rpc").fetch(:automation)

      AutomationRun.create!(
        automation: automation,
        dispatch_key: "#{automation.id}:#{Time.utc(2026, 3, 9, 9, 0, 0).iso8601}",
        status: "completed",
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
        approval_state: {},
        snapshot: { "automation" => { "id" => automation.id } },
      )
    end

    def create_queued_run!
      automation = create_automation_runtime!(endpoint_url: "http://127.0.0.1:4319/rpc").fetch(:automation)

      AutomationRun.create!(
        automation: automation,
        dispatch_key: "#{automation.id}:#{Time.utc(2026, 3, 9, 9, 0, 0).iso8601}",
        status: "queued",
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
        approval_state: {},
        snapshot: { "automation" => { "id" => automation.id } },
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
