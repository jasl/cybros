require "test_helper"

class AutomationSchedulerFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "recurring dispatch executes due active automations once per schedule window" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    due = create_automation!(status: "active", hour: 9, minute: 0, endpoint_url: server.rpc_url)
    paused = create_automation!(status: "paused", hour: 9, minute: 0, endpoint_url: server.rpc_url)
    later = create_automation!(status: "active", hour: 10, minute: 0, endpoint_url: server.rpc_url)
    now = Time.utc(2026, 3, 9, 9, 0, 0)

    due_conversation = dispatch_due_automation!(automation: due, now: now)
    clear_enqueued_jobs

    perform_enqueued_jobs only: [DAG::TickGraphJob, DAG::ExecuteNodeJob] do
      Automations::ConversationOrchestrator.start!(conversation: due_conversation.reload)
    end

    due_conversation.reload
    due_run = ConversationRun.where(conversation: due_conversation).order(:created_at, :id).last
    assert_equal "completed", due_conversation.metadata.dig("automation_execution", "status")
    assert_nil Conversation.find_by(automation: paused)
    assert_nil Conversation.find_by(automation: later)
    assert_equal "#{due.id}:#{now.iso8601}", due_conversation.automation_dispatch_key
    assert_equal now.iso8601, due_conversation.metadata.dig("schedule", "scheduled_for")
    assert_equal "succeeded", due_run.state

    clear_enqueued_jobs
    assert_no_difference -> { Conversation.count } do
      assert_no_enqueued_jobs do
        Automations::DispatchDueJob.perform_now(now: now)
      end
    end
  ensure
    server&.shutdown
  end

  private

    def dispatch_due_automation!(automation:, now:)
      executions = Automations::DispatchDueJob.perform_now(now: now)
      matching_execution = executions.find { |conversation| conversation.automation_id == automation.id }

      assert_not_nil matching_execution
      matching_execution
    end

    def create_automation!(status:, hour:, minute:, endpoint_url:)
      program =
        create_agent_record!(
          name: "Automation Program #{SecureRandom.hex(4)}",
          config_namespace: "automation.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "name" => "Automation Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        create_execution_location_profile!(
          name: "Automation host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["automation"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Automation workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/automation-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["automation"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Automation target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )
      ensure_active_openai_credential!
      deployment = active_deployment!(program:, endpoint_url:, deployment_fingerprint: "fixture-deployment-v1")
      agent = create_agent_runtime!(program: program, execution_target: target, deployment: deployment)

      Automation.create!(
        user: create_user!,
        agent: agent,
        permission_mode: "full_access",
        status: status,
        schedule_kind: "rrule",
        schedule_rrule: "FREQ=DAILY;BYHOUR=#{hour};BYMINUTE=#{minute}",
        schedule_timezone: "UTC",
        task_payload: { "kind" => "scheduled_prompt", "prompt" => "Ship it", "selected_model_ref" => "openai/gpt-5.4" },
      )
    end

    def active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      create_runtime_binding_record!(
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
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
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
