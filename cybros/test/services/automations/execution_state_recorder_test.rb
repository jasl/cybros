require "test_helper"

class Automations::ExecutionStateRecorderTest < ActiveSupport::TestCase
  test "running and completed follow the linked conversation run lifecycle" do
    runtime = create_runtime!
    conversation = runtime.fetch(:conversation)
    conversation_run = runtime.fetch(:conversation_run)

    Automations::ExecutionStateRecorder.running!(conversation: conversation, conversation_run: conversation_run)

    conversation.reload
    assert_equal "running", conversation.metadata.dig("automation_execution", "status")
    assert_equal conversation_run.id, conversation.metadata.dig("automation_execution", "conversation_run_id")
    assert_nil conversation.metadata.dig("automation_execution", "finished_at")

    Automations::ExecutionStateRecorder.completed!(conversation: conversation, conversation_run: conversation_run)

    conversation.reload
    assert_equal "completed", conversation.metadata.dig("automation_execution", "status")
    assert_equal conversation_run.id, conversation.metadata.dig("automation_execution", "conversation_run_id")
    assert conversation.metadata.dig("automation_execution", "finished_at").present?
  end

  test "failed captures structured validation error audit" do
    conversation = create_runtime!.fetch(:conversation)
    error =
      AgentCore::ValidationError.new(
        "Deployment initialize failed.",
        code: "cybros.agent_rpc.initialize_failed",
        details: { "message" => "connection refused" },
      )

    Automations::ExecutionStateRecorder.failed!(conversation: conversation, error: error)

    conversation.reload
    assert_equal "failed", conversation.metadata.dig("automation_execution", "status")
    assert conversation.metadata.dig("automation_execution", "finished_at").present?
    assert_equal "AgentCore::ValidationError", conversation.metadata.dig("automation_execution", "failure", "class")
    assert_equal "cybros.agent_rpc.initialize_failed", conversation.metadata.dig("automation_execution", "failure", "code")
    assert_equal "Deployment initialize failed.", conversation.metadata.dig("automation_execution", "failure", "message")
    assert_equal "connection refused", conversation.metadata.dig("automation_execution", "failure", "details", "message")
  end

  test "attach agent node preserves the current execution status" do
    conversation = create_runtime!.fetch(:conversation)
    Automations::ExecutionStateRecorder.queued!(
      conversation: conversation,
      initiated_by_user: nil,
      scheduled_for: Time.utc(2026, 3, 9, 9, 0, 0),
      dispatch_key: "dispatch-1",
    )

    Automations::ExecutionStateRecorder.attach_agent_node!(conversation: conversation, dag_node_id: "node-1")

    conversation.reload
    assert_equal "queued", conversation.metadata.dig("automation_execution", "status")
    assert_equal "node-1", conversation.metadata.dig("automation_execution", "dag_node_id")
  end

  private

    def create_runtime!
      user = create_user!
      program = create_program!
      target = create_execution_target!(name: "Recorder target")
      deployment = active_deployment!(program: program, endpoint_url: "http://127.0.0.1:9", deployment_fingerprint: "fixture-deployment-v1")
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

      conversation =
        Conversation.create!(
          user: user,
          automation: automation,
          automation_dispatch_key: SecureRandom.uuid,
          automation_triggered_at: Time.current.change(usec: 0),
          title: "Recorder execution",
          agent_program: program,
          default_execution_target: target,
          permission_mode: "full_access",
          metadata: {},
        )

      conversation_run =
        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: SecureRandom.uuid,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          effective_permission_mode: "full_access",
          agent_program: program,
          contract_fingerprint: program.published_contract_fingerprint,
          agent_deployment: deployment,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at,
          provider_credential: LLMProviderCredential.find_by!(provider_key: "openai", status: "active"),
          execution_target: target,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: program.config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: {},
          snapshot: { "draft" => { "id" => SecureRandom.uuid } },
        )

      { conversation: conversation, conversation_run: conversation_run }
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
