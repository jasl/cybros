require "test_helper"

class AutomationFailureRecoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "planning rpc failure marks the execution conversation failed with durable error audit" do
    failing_server = failing_initialize_server!
    runtime = create_automation_runtime!(endpoint_url: failing_server.rpc_url)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    conversation = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)
    clear_enqueued_jobs

    error = assert_raises(AgentCore::ValidationError) { Automations::ExecuteConversationJob.perform_now(conversation.id) }
    conversation.reload

    assert_equal "cybros.agent_rpc.initialize_failed", error.code
    assert_equal "failed", conversation.metadata.dig("automation_execution", "status")
    assert conversation.metadata.dig("automation_execution", "finished_at").present?
    assert_equal "AgentCore::ValidationError", conversation.metadata.dig("automation_execution", "failure", "class")
    assert_equal "cybros.agent_rpc.initialize_failed", conversation.metadata.dig("automation_execution", "failure", "code")
    assert_match(/refused|failed/i, conversation.metadata.dig("automation_execution", "failure", "message").to_s)
  ensure
    failing_server&.shutdown
  end

  test "a later automation redispatch creates a new execution conversation after a failed trigger" do
    failing_server = failing_initialize_server!
    runtime = create_automation_runtime!(endpoint_url: failing_server.rpc_url)
    first_conversation = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))
    clear_enqueued_jobs

    assert_raises(AgentCore::ValidationError) { Automations::ExecuteConversationJob.perform_now(first_conversation.id) }
    assert_equal "failed", first_conversation.reload.metadata.dig("automation_execution", "status")

    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime.fetch(:agent).update!(status: "inactive", health_status: "unhealthy", deactivated_at: Time.current.change(usec: 0))
    deployment =
      active_deployment!(
        program: runtime.fetch(:program),
        endpoint_url: server.rpc_url,
        deployment_fingerprint: "fixture-deployment-v1",
      )
    sync_agent_runtime_from_binding!(agent: runtime.fetch(:agent), deployment: deployment)

    second_conversation = nil

    perform_enqueued_jobs only: Automations::ExecuteConversationJob do
      second_conversation =
        dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 10, 9, 0, 0))
    end
    second_conversation.reload

    assert_not_equal first_conversation.id, second_conversation.id
    assert_equal "running", second_conversation.metadata.dig("automation_execution", "status")
    assert_equal "finalized", second_conversation.run_drafts.order(:created_at, :id).last.status
    assert_equal "failed", first_conversation.reload.metadata.dig("automation_execution", "status")
  ensure
    failing_server&.shutdown
    server&.shutdown
  end

  private

    def create_automation_runtime!(endpoint_url:)
      user = create_user!
      program = create_program!
      deployment = active_deployment!(program: program, endpoint_url: endpoint_url, deployment_fingerprint: "fixture-deployment-v1")
      agent = create_agent_runtime!(agent: program, deployment: deployment)
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

      { agent: agent, automation: automation, program: program }
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
        agent: program,
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

    def failing_initialize_server!
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "initialize" => lambda do |_params, _base_result, _identity|
            raise "initialize refused"
          end,
        },
      ).start
    end
end
