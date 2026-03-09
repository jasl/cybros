require "test_helper"

class RunDraftFinalizationTest < ActiveSupport::TestCase
  test "conversation append_user_message materializes a run from a durable prepared draft" do
    seen_draft_ids = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            seen_draft_ids << params.fetch("run_draft_id")
            base_result
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Plan it", model_ref: "openai/gpt-5.4")

    draft = RunDraft.order(:created_at).last
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: result.fetch(:agent_node).id)

    assert_equal [draft.id], seen_draft_ids
    assert_equal "finalized", draft.status
    assert_equal run.id, draft.materialized_conversation_run_id
    assert_equal true, draft.prepared_plan.fetch("fixture")
    assert_equal runtime.fetch(:target).id, run.execution_target_id
    assert_equal runtime.fetch(:deployment).id, run.agent_deployment_id
    assert_equal "default", run.effective_permission_mode
  ensure
    server&.shutdown
  end

  test "finalization commits staged settings config and kv mutations into conversation state" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Ship it",
        },
      )
    draft.update!(
      staged_public_settings_patch: { "tone" => "concise" },
      staged_agent_config_patch: { "mode" => "review" },
      staged_kv_ops: [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
    )

    run = RunDrafts::FinalizeService.finalize!(draft: draft)

    conversation.reload
    assert_equal "concise", conversation.public_settings.fetch("tone")
    assert_equal({ "mode" => "review" }, conversation.selected_agent_config)
    assert_equal({ "status" => "planned" }, ConversationKVEntry.find_by!(conversation: conversation, key: "shared.stage").value)
    assert_equal run.id, draft.reload.materialized_conversation_run_id
    assert_equal "finalized", draft.status
  ensure
    server&.shutdown
  end

  test "planning pins turn prepare to the draft deployment selected at open time" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    pinned_deployment = runtime.fetch(:deployment)
    alternate_deployment =
      inactive_deployment!(
        program: runtime.fetch(:program),
        endpoint_url: "http://127.0.0.1:1",
        deployment_fingerprint: "deployment:v2",
      )
    service =
      RunDrafts::ConversationTurnPlanningService.new(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Pin deployment",
        },
      )
    deployment_sequence = [pinned_deployment, alternate_deployment]
    singleton = class << service; self; end

    singleton.alias_method :__test_original_resolve_deployment!, :resolve_deployment!
    singleton.define_method(:resolve_deployment!) { deployment_sequence.shift || alternate_deployment }

    draft = service.open_and_prepare!

    assert_equal pinned_deployment.id, draft.agent_deployment_id
    assert_equal "prepared", draft.status
  ensure
    if defined?(singleton) && singleton.method_defined?(:__test_original_resolve_deployment!)
      singleton.alias_method :resolve_deployment!, :__test_original_resolve_deployment!
      singleton.remove_method :__test_original_resolve_deployment!
    end
    server&.shutdown
  end

  test "stale finalization fails and leaves staged mutations uncommitted" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Ship it",
        },
      )
    draft.update!(staged_public_settings_patch: { "tone" => "concise" })
    runtime.fetch(:deployment).update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    replacement_deployment!(
      program: runtime.fetch(:program),
      endpoint_url: server.rpc_url,
      deployment_fingerprint: "deployment:v2",
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", error.code
    assert_equal({}, conversation.reload.public_settings)
    assert_equal "stale", draft.reload.status
    assert_nil draft.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "finalization rejects reusing an already materialized draft" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    dag_node_id = SecureRandom.uuid
    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => dag_node_id,
          "user_input" => "Ship it",
        },
      )

    first_run = RunDrafts::FinalizeService.finalize!(draft: draft)
    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft.reload) }

    assert_equal "cybros.run_drafts.already_finalized", error.code
    assert_equal first_run.id, draft.reload.materialized_conversation_run_id
    assert_equal 1, ConversationRun.where(conversation: conversation, dag_node_id: dag_node_id).count
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:, permission_mode: "default")
      user = create_user!
      program = create_program!
      deployment = active_deployment!(program:, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v1")
      target = create_execution_target!(name: "Primary target")
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: permission_mode,
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation, program: program, deployment: deployment, target: target }
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

    def replacement_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
    end

    def inactive_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
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
