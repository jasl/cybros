require "test_helper"

class RunDraftTest < ActiveSupport::TestCase
  test "requires exactly one entrypoint scope" do
    missing_scope = build_draft(conversation: nil, automation_id: nil)

    refute_predicate missing_scope, :valid?
    assert missing_scope.errors[:base].any?

    both_scopes = build_draft(automation_id: SecureRandom.uuid)

    refute_predicate both_scopes, :valid?
    assert both_scopes.errors[:base].any?
  end

  test "persists prepared plans and staged draft mutations" do
    draft = build_draft

    assert_predicate draft, :valid?
    draft.save!

    assert_equal "default", draft.permission_mode
    assert_equal({ "kind" => "user_turn" }, draft.trigger_snapshot)
    assert_equal({ "steps" => ["draft"] }, draft.prepared_plan)
    assert_equal({ "title" => "Updated" }, draft.staged_public_settings_patch)
    assert_equal([{ "op" => "set", "key" => "shared.stage" }], draft.staged_kv_ops)
  end

  test "enforces the entrypoint invariant at the database layer" do
    conversation = create_conversation!
    program = create_program!
    deployment = create_deployment!(program)
    credential =
      LLMProviderCredential.create!(
        provider_key: "openai-#{SecureRandom.hex(4)}",
        credential_type: "api_key",
      )

    assert_raises(ActiveRecord::StatementInvalid) do
      RunDraft.insert!({
        id: SecureRandom.uuid,
        conversation_id: nil,
        automation_id: nil,
        initiated_by_user_id: conversation.user_id,
        status: "open",
        permission_mode: "default",
        trigger_snapshot: {},
        agent_program_id: program.id,
        contract_fingerprint: "contract:v1",
        agent_deployment_id: deployment.id,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: Time.current.change(usec: 0),
        provider_credential_id: credential.id,
        proposed_execution_target_id: nil,
        selected_model_ref: nil,
        runtime_governors: {},
        prepare_invocation_id: nil,
        prepared_plan: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        approval_state: {},
        expires_at: 30.minutes.from_now.change(usec: 0),
        materialized_conversation_run_id: nil,
        created_at: Time.current.change(usec: 0),
        updated_at: Time.current.change(usec: 0),
      })
    end
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

  private

  def build_draft(attributes = {})
    conversation = attributes.key?(:conversation) ? attributes[:conversation] : create_conversation!
    program = attributes[:agent_program] || create_program!
    deployment = attributes[:agent_deployment] || create_deployment!(program)
    target = ExecutionTarget.first || create_execution_target!
    credential =
      LLMProviderCredential.create!(
        provider_key: "openai-#{SecureRandom.hex(4)}",
        credential_type: "api_key",
      )

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
        provider_credential: credential,
        proposed_execution_target: target,
        selected_model_ref: "openai/gpt-5.4",
        runtime_governors: { "provider_key" => "openai" },
        prepare_invocation_id: "prepare-1",
        prepared_plan: { "steps" => ["draft"] },
        staged_public_settings_patch: { "title" => "Updated" },
        staged_agent_config_patch: { "mode" => "coding" },
        staged_kv_ops: [{ "op" => "set", "key" => "shared.stage" }],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
        automation_id: nil,
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
      supported_methods: %w[initialize turn.prepare turn.compose],
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
    )
  end

  def create_execution_target!
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
      execution_location: location,
      workspace: workspace,
      name: "Fixture target",
      status: "active",
      sandboxed: true,
    )
  end
end
