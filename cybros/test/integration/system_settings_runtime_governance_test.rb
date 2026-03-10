require "test_helper"

class SystemSettingsRuntimeGovernanceIntegrationTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get system_settings_runtime_governance_path

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_as!(role: :member)

    get system_settings_runtime_governance_path

    assert_response :forbidden
  end

  test "show renders current waits and recent runtime outcomes" do
    sign_in_as!(role: :owner)
    provider_credential = create_provider_credential!(provider_key: "openai-ops")
    create_provider_wait!(provider_credential: provider_credential)
    execution_target = create_execution_target!(name: "Observability host")
    create_execution_wait!(execution_target: execution_target)
    create_execution_denial!(execution_target: execution_target)
    deployment = create_deployment_with_backoff!

    get system_settings_runtime_governance_path

    assert_response :success
    assert_includes response.body, "Runtime Governance"
    assert_includes response.body, "Current parked waits"
    assert_includes response.body, "Provider limit"
    assert_includes response.body, "Execution capacity"
    assert_includes response.body, "Deployment backoff"
    assert_includes response.body, provider_credential.provider_key
    assert_includes response.body, execution_target.execution_location.name
    assert_includes response.body, "execution_capacity_denied"
    assert_includes response.body, deployment.agent_program.name
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_provider_wait!(provider_credential:)
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RunDraft",
        owner_id: SecureRandom.uuid,
        reason_type: "provider_limit",
        subject_type: "llm_provider_credential",
        subject_id: provider_credential.id,
        retry_at: 5.minutes.from_now.change(usec: 0),
        details: { "provider_request_id" => "provider-wait-1" },
      )
    end

    def create_execution_wait!(execution_target:)
      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "ConversationRun",
        owner_id: SecureRandom.uuid,
        reason_type: "execution_capacity",
        subject_type: "execution_location",
        subject_id: execution_target.execution_location_id,
        retry_at: 5.minutes.from_now.change(usec: 0),
        details: { "execution_request_id" => "execution-wait-1" },
      )
    end

    def create_execution_denial!(execution_target:)
      conversation = create_conversation!
      program = create_program!
      deployment = create_deployment!(program: program)
      credential = create_provider_credential!(provider_key: "provider-#{SecureRandom.hex(4)}")

      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: SecureRandom.uuid,
        state: "failed",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        initiated_by_user: conversation.user,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: program.published_contract_fingerprint,
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
        provider_credential: credential,
        execution_target: execution_target,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
        effective_policy: {},
        runtime_governors: {
          "provider_limiter" => provider_limiter_snapshot(
            provider_credential: credential,
            selected_model_ref: "openai/gpt-5.4",
          ),
          "execution_capacity" => RuntimeGovernance::ExecutionCapacityResolver.resolve!(execution_target: execution_target),
        },
        snapshot: { "execution_target_id" => execution_target.id },
        error: { "message" => "execution_capacity_denied: queue full" },
      )
    end

    def create_deployment_with_backoff!
      program = create_program!(name: "Deployment backoff")
      deployment = create_deployment!(program: program)

      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "AgentDeployment",
        owner_id: deployment.id,
        reason_type: "deployment_backoff",
        subject_type: "agent_deployment",
        subject_id: deployment.id,
        retry_at: 10.minutes.from_now.change(usec: 0),
        details: { "attempt" => 3 },
      )

      deployment
    end

    def create_provider_credential!(provider_key:)
      LLMProviderCredential.create!(
        provider_key: provider_key,
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
      )
    end

    def create_execution_target!(name:)
      location =
        ExecutionLocation.create!(
          name: name,
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 2,
          max_queued_tasks: 4,
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
        name: "#{name} target",
        status: "active",
        sandboxed: true,
      )
    end

    def create_program!(name: "Observability program")
      AgentProgram.create!(
        name: "#{name} #{SecureRandom.hex(4)}",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
      )
    end

    def create_deployment!(program:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        activated_at: Time.current.change(usec: 0),
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: %w[initialize turn.prepare turn.compose],
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end
end
