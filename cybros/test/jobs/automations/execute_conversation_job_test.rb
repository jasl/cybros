require "test_helper"

class Automations::ExecuteConversationJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  test "perform starts queued execution conversations through the orchestrator" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(endpoint_url: server.rpc_url)
    conversation = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))

    Automations::ExecuteConversationJob.perform_now(conversation.id)

    assert_equal "running", conversation.reload.metadata.dig("automation_execution", "status")
    assert_equal 1, conversation.run_drafts.count
    assert_equal 1, ConversationRun.where(conversation: conversation).count
  ensure
    server&.shutdown
  end

  test "perform ignores conversations that are no longer queued" do
    conversation = create_completed_execution_conversation!

    assert_no_difference -> { RunDraft.count } do
      Automations::ExecuteConversationJob.perform_now(conversation.id)
    end

    assert_equal "completed", conversation.reload.metadata.dig("automation_execution", "status")
  end

  test "perform claims queued execution conversations before orchestration so duplicate delivery is ignored" do
    conversation = create_queued_execution_conversation!
    start_calls = 0
    orchestrator_singleton = Automations::ConversationOrchestrator.singleton_class

    orchestrator_singleton.alias_method :__execute_conversation_job_test_original_start__, :start!
    orchestrator_singleton.define_method(:start!) do |conversation:, **|
      start_calls += 1
      conversation
    end

    begin
      Automations::ExecuteConversationJob.perform_now(conversation.id)
      Automations::ExecuteConversationJob.perform_now(conversation.id)
    ensure
      orchestrator_singleton.alias_method :start!, :__execute_conversation_job_test_original_start__
      orchestrator_singleton.remove_method :__execute_conversation_job_test_original_start__
    end

    assert_equal 1, start_calls
    assert_equal "planning", conversation.reload.metadata.dig("automation_execution", "status")
  end

  test "perform marks the execution conversation failed if orchestration raises a non-standard exception after claim" do
    conversation = create_queued_execution_conversation!
    crash_class = Class.new(Exception)
    orchestrator_singleton = Automations::ConversationOrchestrator.singleton_class

    orchestrator_singleton.alias_method :__execute_conversation_job_test_original_start__, :start!
    orchestrator_singleton.define_method(:start!) do |**|
      raise crash_class, "hard crash"
    end

    error =
      begin
        assert_raises(crash_class) { Automations::ExecuteConversationJob.perform_now(conversation.id) }
      ensure
        orchestrator_singleton.alias_method :start!, :__execute_conversation_job_test_original_start__
        orchestrator_singleton.remove_method :__execute_conversation_job_test_original_start__
      end

    assert_equal "hard crash", error.message
    assert_equal "failed", conversation.reload.metadata.dig("automation_execution", "status")
    assert_equal "hard crash", conversation.metadata.dig("automation_execution", "failure", "message")
  end

  private

    def create_automation_runtime!(endpoint_url:)
      user = create_user!
      program = create_program!
      deployment = active_deployment!(program: program, endpoint_url: endpoint_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Automation target")
      agent = create_agent_runtime!(program: program, execution_target: target, deployment: deployment)
      ensure_active_openai_credential!
      automation =
        Automation.create!(
          user: user,
          agent: agent,
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

      { agent: agent, automation: automation, program: program, target: target }
    end

    def dispatch_automation!(automation:, scheduled_for:)
      Automations::Dispatch.call!(
        automation: automation,
        scheduled_for: scheduled_for,
        dispatch_key: "#{automation.id}:#{scheduled_for.iso8601}",
        trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
      )
    end

    def create_completed_execution_conversation!
      conversation = create_queued_execution_conversation!
      conversation.update!(
        metadata: conversation.metadata.deep_merge("automation_execution" => { "status" => "completed" }),
      )
      conversation
    end

    def create_queued_execution_conversation!
      automation = create_automation_runtime!(endpoint_url: "http://127.0.0.1:4319/rpc").fetch(:automation)
      dispatch_automation!(automation: automation, scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))
    end

    def create_program!
      create_agent_record!(
        name: "Fixture Program",
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

    def create_execution_target!(name:)
      location =
        create_execution_location_profile!(
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
        create_workspace_profile!(
          execution_location: location,
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
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
