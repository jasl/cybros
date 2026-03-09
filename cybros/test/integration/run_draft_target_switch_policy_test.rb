require "test_helper"

class RunDraftTargetSwitchPolicyTest < ActiveSupport::TestCase
  test "execution_target propose confirms different visible targets under default mode and stages the requested target on the draft" do
    conversation = create_conversation!(permission_mode: "default")
    current_target = create_execution_target!(name: "Current target")
    alternate_target = create_execution_target!(name: "Alternate target")
    conversation.update!(default_execution_target: current_target)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
    draft = build_draft(conversation:, proposed_execution_target: current_target, permission_mode: "default")

    result = AgentRpc::KernelServices::ExecutionTargets.propose!(draft:, execution_target_id: alternate_target.id)

    assert_equal "confirm", result.dig("switch_decision", "decision")
    assert_equal alternate_target.id, draft.reload.proposed_execution_target_id
    assert_equal alternate_target.id, draft.runtime_governors.dig("execution_quota", "execution_target_id")
  end

  test "execution_target propose allows validated target switches under full access and re-resolves governors" do
    conversation = create_conversation!(permission_mode: "full_access")
    current_target = create_execution_target!(name: "Current target")
    alternate_target =
      create_execution_target!(
        name: "Alternate target",
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 5,
        default_timeout_s_override: 600,
      )
    conversation.update!(default_execution_target: current_target)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
    draft = build_draft(conversation:, proposed_execution_target: current_target, permission_mode: "full_access")

    result = AgentRpc::KernelServices::ExecutionTargets.propose!(draft:, execution_target_id: alternate_target.id)

    assert_equal "allow", result.dig("switch_decision", "decision")
    assert_equal alternate_target.id, draft.reload.proposed_execution_target_id
    assert_equal "execution_target", draft.runtime_governors.dig("execution_quota", "scope_type")
    assert_equal alternate_target.id, draft.runtime_governors.dig("execution_quota", "execution_target_id")
    assert_equal 2, draft.runtime_governors.dig("execution_quota", "max_concurrent_tasks")
  end

  test "execution_target propose denies invisible or inactive targets" do
    conversation = create_conversation!(permission_mode: "full_access")
    current_target = create_execution_target!(name: "Current target")
    inactive_target = create_execution_target!(name: "Inactive target", target_status: "inactive")
    conversation.update!(default_execution_target: current_target)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
    draft = build_draft(conversation:, proposed_execution_target: current_target, permission_mode: "full_access")

    result = AgentRpc::KernelServices::ExecutionTargets.propose!(draft:, execution_target_id: inactive_target.id)

    assert_equal "deny", result.dig("switch_decision", "decision")
    assert_equal current_target.id, draft.reload.proposed_execution_target_id
    assert_equal current_target.id, draft.runtime_governors.dig("execution_quota", "execution_target_id")
  end

  test "execution_target propose supports automation-backed drafts" do
    current_target = create_execution_target!(name: "Current target")
    alternate_target = create_execution_target!(name: "Alternate target", max_concurrent_tasks_override: 2)
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
    draft =
      build_draft(
        conversation: nil,
        automation_id: SecureRandom.uuid,
        initiated_by_user: nil,
        proposed_execution_target: current_target,
        permission_mode: "full_access",
      )

    result = AgentRpc::KernelServices::ExecutionTargets.propose!(draft:, execution_target_id: alternate_target.id)

    assert_equal "allow", result.dig("switch_decision", "decision")
    assert_equal alternate_target.id, draft.reload.proposed_execution_target_id
    assert_equal "execution_target", draft.runtime_governors.dig("execution_quota", "scope_type")
  end

  private

    def build_draft(conversation:, proposed_execution_target:, permission_mode:, automation_id: nil, initiated_by_user: conversation&.user)
      program = create_program!
      deployment = create_deployment!(program)
      provider_credential = LLMProviderCredential.find_by(provider_key: "openai")

      RunDraft.create!(
        conversation: conversation,
        automation_id: automation_id,
        status: "open",
        permission_mode: permission_mode,
        trigger_snapshot: { "kind" => "user_turn" },
        initiated_by_user: initiated_by_user,
        agent_program: program,
        contract_fingerprint: program.published_contract_fingerprint,
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: Time.current.change(usec: 0),
        provider_credential: provider_credential,
        proposed_execution_target: proposed_execution_target,
        selected_model_ref: "openai/gpt-5.4",
        runtime_governors: resolved_governor_snapshot(provider_credential:, execution_target: proposed_execution_target),
        prepare_invocation_id: "prepare-1",
        prepared_plan: { "steps" => ["draft"] },
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      )
    end

    def create_conversation!(permission_mode:)
      identity =
        Identity.create!(
          email: "owner-#{SecureRandom.hex(4)}@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )
      user = User.create!(identity:, role: :owner)

      Conversation.create!(
        user: user,
        title: "Chat",
        permission_mode: permission_mode,
        metadata: {},
      )
    end

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "name" => "Fixture" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_deployment!(program)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: %w[initialize turn.prepare turn.compose],
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end

    def create_execution_target!(name:, target_status: "active", max_concurrent_tasks_override: nil, max_queued_tasks_override: nil, default_timeout_s_override: nil)
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
        status: target_status,
        sandboxed: true,
        max_concurrent_tasks_override: max_concurrent_tasks_override,
        max_queued_tasks_override: max_queued_tasks_override,
        default_timeout_s_override: default_timeout_s_override,
      )
    end

    def resolved_governor_snapshot(provider_credential:, execution_target:)
      {
        "provider_limiter" => {
          "provider_key" => provider_credential.provider_key,
          "provider_credential_id" => provider_credential.id,
          "credential_type" => provider_credential.credential_type,
          "max_concurrent_requests" => provider_credential.max_concurrent_requests,
          "requests_per_minute" => provider_credential.requests_per_minute,
          "tokens_per_minute" => provider_credential.tokens_per_minute,
          "burst_limit" => provider_credential.burst_limit,
          "backoff_policy" => provider_credential.backoff_policy.deep_stringify_keys,
        },
        "execution_quota" => {
          "scope_type" => "execution_location",
          "scope_id" => execution_target.execution_location_id,
          "execution_location_id" => execution_target.execution_location_id,
          "execution_target_id" => execution_target.id,
          "override_applied" => false,
          "max_concurrent_tasks" => execution_target.execution_location.max_concurrent_tasks,
          "max_queued_tasks" => execution_target.execution_location.max_queued_tasks,
          "default_timeout_s" => execution_target.execution_location.default_timeout_s,
          "cpu_limit_millicores" => execution_target.execution_location.cpu_limit_millicores,
          "memory_limit_mb" => execution_target.execution_location.memory_limit_mb,
        },
      }
    end
end
