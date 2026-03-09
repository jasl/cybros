require "test_helper"

class AutomationConversationBindingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "automation conversation binding links the materialized conversation run" do
    seen_conversation_ids = []
    seen_agent_configs = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            seen_conversation_ids << params["conversation_id"]
            seen_agent_configs << params["agent_config"]
            base_result
          end,
        },
      ).start
    runtime = create_automation_runtime!(server:)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    result = Automations::RunOrchestrator.start!(automation_run: automation_run)

    draft = result.fetch(:draft)
    conversation_run = result.fetch(:conversation_run)
    automation_run.reload

    assert_equal [runtime.fetch(:conversation).id], seen_conversation_ids
    assert_equal [{ "mode" => "automation" }], seen_agent_configs
    assert_equal runtime.fetch(:conversation).id, conversation_run.conversation_id
    assert_equal({ "mode" => "automation" }, conversation_run.effective_agent_config)
    assert_equal conversation_run.id, automation_run.conversation_run_id
    assert_equal conversation_run.id, draft.materialized_conversation_run_id
    assert_equal automation_run.id, conversation_run.snapshot.dig("draft", "trigger_snapshot", "automation_run_id")
    assert_equal runtime.fetch(:conversation).id, automation_run.snapshot.dig("runtime", "conversation_id")
    assert_equal "running", automation_run.status
  ensure
    server&.shutdown
  end

  test "rejecting a conversation-bound automation approval updates the bound agent node" do
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
    runtime = create_automation_runtime!(server:, permission_mode: "default")
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    draft = Automations::RunOrchestrator.start!(automation_run: automation_run).fetch(:draft)
    conversation = runtime.fetch(:conversation)
    agent_node = conversation.root_graph.nodes.find(draft.trigger_snapshot.fetch("dag_node_id"))

    assert_equal "awaiting_approval", draft.status
    assert_equal DAG::Node::AWAITING_APPROVAL, agent_node.reload.state

    draft.update!(
      approval_state: draft.approval_state.merge("status" => "rejected", "reason" => "operator_denied"),
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "operator_denied", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  test "automation conversation binding creates an executable agent node" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    result = Automations::RunOrchestrator.start!(automation_run: automation_run)

    conversation = runtime.fetch(:conversation)
    conversation_run = result.fetch(:conversation_run)
    agent_node = conversation.root_graph.nodes.find(conversation_run.dag_node_id)
    agent_node.update!(claim_after_at: nil)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
    assert_includes claimed, agent_node.id

    DAG::Runner.run_node!(agent_node.id)

    assert_equal DAG::Node::FINISHED, agent_node.reload.state
    assert_equal "fixture compose response", agent_node.body_output.fetch("content")
    assert_equal "succeeded", conversation_run.reload.state
    assert_equal "completed", automation_run.reload.status
  ensure
    server&.shutdown
  end

  test "automation conversation binding kicks the bound graph for execution" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)

    assert_enqueued_jobs 1, only: DAG::TickGraphJob do
      Automations::RunOrchestrator.start!(automation_run: automation_run)
    end
  ensure
    server&.shutdown
  end

  test "conversation-bound automation drafts read settings config and kv through the bound conversation" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_automation_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    ConversationKVEntry.create!(
      conversation: conversation,
      key: "shared.stage",
      value: { "status" => "seeded" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))
    draft = RunDrafts::AutomationPlanningService.open_and_prepare!(automation_run: automation_run)

    assert_nil draft.conversation_id
    assert_equal conversation.id, draft.trigger_snapshot.fetch("conversation_id")
    assert_equal(
      { "settings" => conversation.public_settings },
      AgentRpc::KernelServices::ConversationSettings.get(draft: draft),
    )
    assert_equal(
      { "config" => { "mode" => "automation" } },
      AgentRpc::KernelServices::ConversationConfig.get(draft: draft),
    )
    assert_equal(
      { "entry" => { "key" => "shared.stage", "value" => { "status" => "seeded" } } },
      AgentRpc::KernelServices::ConversationKV.get(draft: draft, key: "shared.stage"),
    )
    assert_equal(
      [{ "key" => "shared.stage", "value" => { "status" => "seeded" } }],
      AgentRpc::KernelServices::ConversationKV.list(draft: draft).fetch("entries"),
    )
  ensure
    server&.shutdown
  end

  test "approval expiry rejects the bound automation agent node even when draft conversation is nil" do
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
    runtime = create_automation_runtime!(server:, permission_mode: "default")
    automation_run = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0))
    draft = Automations::RunOrchestrator.start!(automation_run: automation_run).fetch(:draft)
    agent_node_id = draft.trigger_snapshot.fetch("dag_node_id")
    agent_node = runtime.fetch(:conversation).root_graph.nodes.find(agent_node_id)

    assert_equal "awaiting_approval", draft.status
    assert_equal DAG::Node::AWAITING_APPROVAL, agent_node.reload.state

    draft.update!(
      expires_at: 1.minute.ago,
    )

    RunDrafts::ApprovalExpiryService.expire!(draft: draft)

    assert_equal "expired", draft.reload.status
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "approval_expired", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  private

    def create_automation_runtime!(server:, permission_mode: "full_access")
      user = create_user!
      program = create_program!
      alternate_program = create_program!
      deployment = active_deployment!(program: program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Automation target")
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Automation transcript")
      conversation.update!(
        agent_program: alternate_program,
        default_execution_target: target,
        permission_mode: permission_mode,
        agent_config: {
          program.config_namespace => { "mode" => "automation" },
          alternate_program.config_namespace => { "mode" => "conversation" },
        },
        agent_config_schema_fingerprint: alternate_program.config_schema_fingerprint,
      )
      automation =
        Automation.create!(
          user: user,
          conversation: conversation,
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

      { automation: automation, conversation: conversation, program: program, deployment: deployment, target: target }
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
