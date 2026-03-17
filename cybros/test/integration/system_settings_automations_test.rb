require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class SystemSettingsAutomationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

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

  test "index and show expose execution conversation history" do
    sign_in_owner!
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "automation completed")
      end.start
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    with_catalog_yaml(mock_openai_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "full_access")
      scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
      execution_conversation = dispatch_due_automation!(automation: runtime.fetch(:automation), now: scheduled_for)
      clear_enqueued_jobs

      perform_enqueued_jobs only: [DAG::TickGraphJob, DAG::ExecuteNodeJob] do
        Automations::ConversationOrchestrator.start!(conversation: execution_conversation.reload)
      end

      get system_settings_automations_path

      assert_response :success
      assert_includes response.body, runtime.fetch(:automation).task_payload.fetch("prompt")
      assert_includes response.body, runtime.fetch(:agent).name
      assert_includes response.body, "full_access"
      assert_includes response.body, "completed"
      refute_includes response.body, "Standalone"

      get system_settings_automation_path(runtime.fetch(:automation))

      assert_response :success
      assert_includes response.body, runtime.fetch(:agent).name
      assert_includes response.body, runtime.fetch(:agent).config_namespace
      assert_includes response.body, "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
      assert_includes response.body, "UTC"
      assert_includes response.body, scheduled_for.iso8601
      assert_includes response.body, "completed"
      assert_includes response.body, execution_conversation.id
      refute_includes response.body, "Conversation binding"
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "show supports operator approval for parked automation executions" do
    sign_in_owner!
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "automation approved")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
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
    with_catalog_yaml(mock_openai_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_automation_runtime!(endpoint_url: server.rpc_url, permission_mode: "default")
      scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
      execution_conversation = nil

      perform_enqueued_jobs only: Automations::ExecuteConversationJob do
        execution_conversation = dispatch_automation!(automation: runtime.fetch(:automation), scheduled_for: scheduled_for)
      end

      get system_settings_automation_path(runtime.fetch(:automation))

      assert_response :success
      assert_includes response.body, "awaiting_approval"
      assert_includes response.body, "pending_confirmation"
      assert_includes response.body, "Approve"
      assert_includes response.body, "Reject"

      perform_enqueued_jobs only: [DAG::TickGraphJob, DAG::ExecuteNodeJob] do
        post approve_system_settings_automation_execution_path(runtime.fetch(:automation), execution_conversation)
      end

      assert_redirected_to system_settings_automation_path(runtime.fetch(:automation))
      follow_redirect!

      execution_conversation.reload
      draft = execution_conversation.run_drafts.order(:created_at, :id).last
      agent_node = execution_conversation.root_graph.nodes.find_by(id: execution_conversation.metadata.dig("automation_execution", "dag_node_id"))

      assert_equal "approved", draft.approval_state.fetch("status")
      assert_equal(
        "completed",
        execution_conversation.metadata.dig("automation_execution", "status"),
        "automation failure=#{execution_conversation.metadata.dig("automation_execution", "failure").inspect} node_state=#{agent_node&.state.inspect} node_metadata=#{agent_node&.metadata.inspect} node_body_output=#{agent_node&.body_output.inspect}",
      )
      assert_includes response.body, "completed"
      assert_includes response.body, "approved"
    end
  ensure
    llm_server&.shutdown
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
      deployment = active_deployment!(program: program, endpoint_url: endpoint_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Operator automation target")
      agent = create_agent_runtime!(program: program, execution_target: target, deployment: deployment)
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
            "prompt" => "Nightly automation",
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

    def dispatch_due_automation!(automation:, now:)
      executions = Automations::Scheduler.dispatch_due!(now: now)
      matching_execution = executions.find { |conversation| conversation.automation_id == automation.id }

      assert_not_nil matching_execution

      matching_execution
    end

    def create_program!
      create_agent_record!(
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

    def mock_openai_catalog_yaml(base_url:)
      <<~YAML
        version: 1
        default_model_ref: "openai/gpt-5.4"
        providers:
          openai:
            display_name: "OpenAI"
            enabled: true
            adapter_key: "openai"
            base_url: "#{base_url}"
            headers: {}
            requires_credential: false
            wire_api: "chat_completions"
            transport: "http"
            models:
              gpt-5.4:
                display_name: "GPT-5.4"
                api_model: "gpt-5.4"
                context_window_tokens: 20000
                capabilities:
                  input: { text: true, image: false }
                  tools: { tool_calling: true }
                  protocol: "chat_completions"
      YAML
    end
end
