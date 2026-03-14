require "test_helper"

class AutomationExecutionConversationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "each automation trigger creates a fresh execution conversation" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)
    automation = runtime.fetch(:automation)

    assert_equal runtime.fetch(:agent).id, automation.agent_id

    first =
      perform_dispatch!(
        automation: automation,
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
      )
    second =
      perform_dispatch!(
        automation: automation,
        scheduled_for: Time.utc(2026, 3, 10, 9, 0, 0),
      )

    assert_not_equal first.id, second.id
    assert_equal automation.id, first.automation_id
    assert_equal automation.id, second.automation_id
    assert_equal 2, automation.conversations.count
    assert_equal runtime.fetch(:agent).id, first.agent_id
    assert_equal runtime.fetch(:agent).id, second.agent_id
    assert_equal runtime.fetch(:agent).config_schema_fingerprint, first.agent_config_schema_fingerprint
    assert_equal runtime.fetch(:agent).config_schema_fingerprint, second.agent_config_schema_fingerprint
  ensure
    server&.shutdown
  end

  test "dispatching the same trigger delivery reuses the same execution conversation" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)

    first = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)
    second = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    assert_equal first.id, second.id
    assert_equal 1, runtime.fetch(:automation).conversations.count
  ensure
    server&.shutdown
  end

  test "automation execution materializes the only run on the execution conversation" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)

    conversation =
      perform_dispatch!(
        automation: runtime.fetch(:automation),
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
      )

    draft = conversation.run_drafts.order(:created_at, :id).last
    run = ConversationRun.where(conversation: conversation).order(:created_at, :id).last

    assert_equal "finalized", draft.status
    assert_equal run.id, draft.materialized_conversation_run_id
    assert_equal conversation.id, run.conversation_id
    assert_equal runtime.fetch(:agent).id, run.agent_id
    assert_equal draft.recognized_deployment_id, run.recognized_deployment_id
    assert_equal run.id, conversation.metadata.dig("automation_execution", "conversation_run_id")
    assert_equal conversation.id, run.snapshot.dig("draft", "trigger_snapshot", "conversation_id")
    assert_equal conversation.automation_id, run.snapshot.dig("draft", "trigger_snapshot", "automation_id")
  ensure
    server&.shutdown
  end

  test "rejecting a parked automation execution updates the execution conversation and parked node" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "planning" => {
                "approval_request" => {
                  "status" => "pending_confirmation",
                  "reason" => "fixture_approval",
                },
              },
            )
          end,
        },
      ).start
    runtime = create_automation_runtime!(server:, permission_mode: "default")
    conversation =
      perform_dispatch!(
        automation: runtime.fetch(:automation),
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
      )

    draft = conversation.run_drafts.order(:created_at, :id).last
    agent_node = conversation.root_graph.nodes.find(draft.trigger_snapshot.fetch("dag_node_id"))

    draft.update!(
      approval_state: draft.approval_state.merge("status" => "rejected", "reason" => "operator_denied"),
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal "rejected", conversation.reload.metadata.dig("automation_execution", "status")
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "operator_denied", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  test "approval expiry rejects the parked automation execution node" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "planning" => {
                "approval_request" => {
                  "status" => "pending_confirmation",
                  "reason" => "fixture_approval",
                },
              },
            )
          end,
        },
      ).start
    runtime = create_automation_runtime!(server:, permission_mode: "default")
    conversation =
      perform_dispatch!(
        automation: runtime.fetch(:automation),
        scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
      )

    draft = conversation.run_drafts.order(:created_at, :id).last
    agent_node = conversation.root_graph.nodes.find(draft.trigger_snapshot.fetch("dag_node_id"))
    expected_recognized_deployment_key = draft.recognized_deployment_key
    expected_capacity_scope_id = draft.runtime_governors.dig("execution_capacity", "scope_id")
    draft.update!(expires_at: 1.minute.ago)

    RunDrafts::ApprovalExpiryService.expire!(draft: draft)

    assert_equal "expired", draft.reload.status
    assert_equal expected_recognized_deployment_key, draft.recognized_deployment_key
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal expected_capacity_scope_id, draft.runtime_governors.dig("execution_capacity", "scope_id")
    assert_equal "canceled", conversation.reload.metadata.dig("automation_execution", "status")
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "approval_expired", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  private

    def perform_dispatch!(automation:, scheduled_for:)
      conversation = nil

      perform_enqueued_jobs only: Automations::ExecuteConversationJob do
        conversation = dispatch_automation!(automation: automation, scheduled_for: scheduled_for)
      end

      conversation.reload
    end

    def create_automation_runtime!(server:, permission_mode: "full_access")
      user = create_user!
      program = create_program!
      deployment = active_deployment!(program: program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Automation target")
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      ensure_active_openai_credential!
      automation =
        Automation.create!(
          user: user,
          agent: agent,
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

      { agent: agent, automation: automation, program: program, deployment: deployment, target: target }
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
