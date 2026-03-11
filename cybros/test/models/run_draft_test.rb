require "test_helper"

class RunDraftTest < ActiveSupport::TestCase
  test "requires a conversation entrypoint" do
    draft = build_draft(conversation: nil)

    refute_predicate draft, :valid?
    assert_includes draft.errors[:conversation], "must exist"
  end

  test "does not expose automation ownership attributes" do
    assert_nil RunDraft.reflect_on_association(:automation)
    assert_not_includes RunDraft.column_names, "automation_id"
    assert_equal false, RunDraft.columns_hash.fetch("conversation_id").null
    refute_respond_to RunDraft.new, :automation_id
    assert_raises(ActiveModel::UnknownAttributeError) do
      RunDraft.new(automation_id: SecureRandom.uuid)
    end
  end

  test "persists planning envelopes and staged draft mutations" do
    draft = build_draft

    assert_predicate draft, :valid?
    draft.save!

    assert_equal "default", draft.permission_mode
    assert_equal({ "kind" => "user_turn" }, draft.trigger_snapshot)
    assert_equal({ "steps" => ["draft"] }, draft.planning)
    assert_equal({ "title" => "Updated" }, draft.staged_public_settings_patch)
    assert_equal([{ "op" => "set", "key" => "shared.stage" }], draft.staged_kv_ops)
    assert_equal(
      [{
        "op" => "put",
        "entry" => {
          "id" => "entry-1",
          "buffer_name" => "summaries",
          "seq" => 10,
          "kind" => "summary",
          "content" => "Snapshot",
          "priority" => 2,
          "estimated_tokens" => 6,
          "metadata" => { "source" => "prepare" },
        },
      }],
      draft.staged_prompt_buffer_ops,
    )
    assert_equal "config:v1", draft.agent_config_schema_fingerprint
    assert_equal draft.provider_credential_id, draft.runtime_governors.dig("provider_limiter", "provider_credential_id")
    assert_equal draft.proposed_execution_target_id, draft.runtime_governors.dig("execution_capacity", "execution_target_id")
  end

  test "requires an agent config schema fingerprint snapshot" do
    draft = build_draft(agent_config_schema_fingerprint: nil)

    refute_predicate draft, :valid?
    assert_includes draft.errors[:agent_config_schema_fingerprint], "can't be blank"
  end

  test "bound_conversation only uses the explicit conversation association" do
    conversation = create_conversation!
    draft = build_draft(conversation: nil, trigger_snapshot: { "conversation_id" => conversation.id })

    assert_nil draft.bound_conversation
  end

  test "requires deployment and contract bindings to match the selected program" do
    program = create_program!
    other_program =
      AgentProgram.create!(
        name: "Other Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v2",
        manifest_snapshot: { "name" => "Other" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v2",
      )
    deployment = create_deployment!(program)

    draft =
      build_draft(
        agent_program: other_program,
        agent_deployment: deployment,
        contract_fingerprint: other_program.published_contract_fingerprint,
      )

    refute_predicate draft, :valid?
    assert_includes draft.errors[:agent_deployment], "must belong to the selected agent program"
    assert_includes draft.errors[:contract_fingerprint], "must match the deployed contract"
  end

  test "requires runtime governor snapshots to match the selected provider and target bindings" do
    draft =
      build_draft(
        runtime_governors: {
          "provider_limiter" => {
            "provider_key" => "anthropic",
            "provider_credential_id" => SecureRandom.uuid,
          },
          "execution_capacity" => {
            "execution_target_id" => SecureRandom.uuid,
            "execution_location_id" => SecureRandom.uuid,
          },
        },
      )

    refute_predicate draft, :valid?
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected provider credential"
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected model provider"
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected execution target"
    assert_includes draft.errors[:runtime_governors], "must snapshot the target execution location"
  end

  test "snapshots resolved governor facts from a conversation entrypoint" do
    conversation = create_conversation!
    target = create_execution_target!
    conversation.update!(default_execution_target: target, permission_mode: "conservative")
    credential =
      LLMProviderCredential.create!(
        provider_key: "openai",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 3,
        requests_per_minute: 90,
        tokens_per_minute: 180_000,
        burst_limit: 6,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      )
    draft = build_draft(conversation: conversation, proposed_execution_target: nil, provider_credential: nil, runtime_governors: {}, permission_mode: nil)

    RuntimeGovernance::DraftGovernorResolver.apply!(
      draft: draft,
      entrypoint: conversation,
      selected_model_ref: "openai/gpt-5.4",
    )

    assert_equal "conservative", draft.permission_mode
    assert_equal credential, draft.provider_credential
    assert_equal target, draft.proposed_execution_target
    assert_equal "openai/gpt-5.4", draft.selected_model_ref
    assert_equal credential.id, draft.runtime_governors.dig("provider_limiter", "provider_credential_id")
    assert_equal target.id, draft.runtime_governors.dig("execution_capacity", "execution_target_id")
    assert_equal "execution_location", draft.runtime_governors.dig("execution_capacity", "scope_type")
  end

  test "re-resolves governor facts after an accepted target change" do
    conversation = create_conversation!
    original_target = create_execution_target!
    override_target =
      create_execution_target!(
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 5,
        default_timeout_s_override: 600,
      )
    conversation.update!(default_execution_target: original_target)
    LLMProviderCredential.create!(provider_key: "openai", credential_type: "api_key", status: "active", api_key: "sk-test")
    draft = build_draft(conversation: conversation, proposed_execution_target: nil, provider_credential: nil, runtime_governors: {})

    RuntimeGovernance::DraftGovernorResolver.apply!(
      draft: draft,
      entrypoint: conversation,
      selected_model_ref: "openai/gpt-5.4",
    )
    RuntimeGovernance::DraftGovernorResolver.apply!(
      draft: draft,
      entrypoint: conversation,
      selected_model_ref: "openai/gpt-5.4",
      execution_target: override_target,
    )

    assert_equal override_target, draft.proposed_execution_target
    assert_equal "execution_target", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal 2, draft.runtime_governors.dig("execution_capacity", "max_concurrent_tasks")
    assert_equal 5, draft.runtime_governors.dig("execution_capacity", "max_queued_tasks")
    assert_equal 600, draft.runtime_governors.dig("execution_capacity", "default_timeout_s")
  end

  private

  def build_draft(attributes = {})
    conversation = attributes.key?(:conversation) ? attributes[:conversation] : create_conversation!
    program = attributes[:agent_program] || create_program!
    deployment = attributes[:agent_deployment] || create_deployment!(program)
    target =
      if attributes.key?(:proposed_execution_target)
        attributes[:proposed_execution_target]
      else
        ExecutionTarget.first || create_execution_target!
      end
    credential =
      if attributes.key?(:provider_credential)
        attributes[:provider_credential]
      else
        ensure_llm_provider!(
          provider_key: "openai",
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        )
      end
    runtime_governors =
      if attributes.key?(:runtime_governors)
        attributes[:runtime_governors]
      elsif credential.present? && target.present?
        resolved_governor_snapshot(provider_credential: credential, execution_target: target)
      else
        {}
      end

    RunDraft.new(
      {
        conversation: conversation,
        status: "open",
        permission_mode: "default",
        trigger_snapshot: { "kind" => "user_turn" },
        agent_program: program,
        contract_fingerprint: "contract:v1",
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: Time.current.change(usec: 0),
        agent_config_schema_fingerprint: "config:v1",
        provider_credential: credential,
        proposed_execution_target: target,
        selected_model_ref: "openai/gpt-5.4",
        runtime_governors: runtime_governors,
        prepare_invocation_id: "prepare-1",
        planning: { "steps" => ["draft"] },
        staged_public_settings_patch: { "title" => "Updated" },
        staged_agent_config_patch: { "mode" => "coding" },
        staged_kv_ops: [{ "op" => "set", "key" => "shared.stage" }],
        staged_prompt_buffer_ops: [{
          "op" => "put",
          "entry" => {
            "id" => "entry-1",
            "buffer_name" => "summaries",
            "seq" => 10,
            "kind" => "summary",
            "content" => "Snapshot",
            "priority" => 2,
            "estimated_tokens" => 6,
            "metadata" => { "source" => "prepare" },
          },
        }],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      }.merge(attributes.except(:conversation)),
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
      contract_fingerprint: "contract:v1",
      deployment_fingerprint: "deployment:v1",
      status: "active",
      health_status: "healthy",
      protocol_version: "agent_rpc.v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      supported_methods: AgentDeployments::REQUIRED_METHODS,
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
    )
  end

  def create_execution_target!(attributes = {})
    location =
      ExecutionLocation.create!(
        name: "Fixture host",
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
        name: "Fixture workspace",
        root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
        capability_tags: ["git"],
        tags: ["fixture"],
      )

    ExecutionTarget.create!(
      {
        execution_location: location,
        workspace: workspace,
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      }.merge(attributes),
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
      "execution_capacity" => {
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
