require "test_helper"

class AutomationFailureRecoveryTest < ActiveSupport::TestCase
  test "planning rpc failure marks the automation run failed with durable error audit" do
    runtime = create_automation_runtime!(endpoint_url: "http://127.0.0.1:9")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    error = assert_raises(AgentCore::ValidationError) { Automations::RunOrchestrator.start!(automation_run: automation_run) }
    automation_run.reload

    assert_equal "cybros.agent_rpc.initialize_failed", error.code
    assert_equal "failed", automation_run.status
    assert automation_run.finished_at.present?
    assert_equal "AgentCore::ValidationError", automation_run.snapshot.dig("failure", "class")
    assert_equal "cybros.agent_rpc.initialize_failed", automation_run.snapshot.dig("failure", "code")
    assert_match(/refused|failed/i, automation_run.snapshot.dig("failure", "message").to_s)
  end

  test "a later automation redispatch can complete after a failed run" do
    runtime = create_automation_runtime!(endpoint_url: "http://127.0.0.1:9")
    first_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))

    assert_raises(AgentCore::ValidationError) { Automations::RunOrchestrator.start!(automation_run: first_run) }
    assert_equal "failed", first_run.reload.status

    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime.fetch(:program).active_healthy_deployment.update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    active_deployment!(
      program: runtime.fetch(:program),
      endpoint_url: server.rpc_url,
      deployment_fingerprint: "fixture-deployment-v1",
    )

    second_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 10, 9, 0, 0))

    result = Automations::RunOrchestrator.start!(automation_run: second_run)
    second_run.reload

    assert_equal "completed", second_run.status
    assert_equal "finalized", result.fetch(:draft).status
    assert_nil result.fetch(:conversation_run)
    assert_equal first_run.id, first_run.reload.id
    assert_equal "failed", first_run.status
  ensure
    server&.shutdown
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
