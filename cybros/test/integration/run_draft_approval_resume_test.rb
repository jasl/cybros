require "test_helper"

class RunDraftApprovalResumeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "approval park marks the agent node awaiting approval and resume finalizes without a second turn prepare" do
    prepare_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            prepare_calls << :called
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "target_switch",
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    assert_equal "awaiting_approval", draft.status
    assert_equal true, draft.prepared_plan.fetch("fixture")
    assert_equal 1, prepare_calls.size
    assert_nil draft.materialized_conversation_run_id
    assert_equal DAG::Node::AWAITING_APPROVAL, agent_node.reload.state

    error =
      assert_raises(Cybros::Error) do
        conversation.start_pending_agent_node!(node_id: agent_node.id, claimed_by: "manual-start:test")
      end
    assert_equal "state_changed", error.message

    draft.update!(approval_state: draft.approval_state.merge("status" => "approved"))
    run = RunDrafts::ApprovalResumeService.resume!(draft: draft)

    assert_equal 1, prepare_calls.size
    assert_equal run.id, draft.reload.materialized_conversation_run_id
    assert_equal "finalized", draft.status
    assert_equal DAG::Node::PENDING, agent_node.reload.state
  ensure
    server&.shutdown
  end

  test "planning preserves kernel-owned target switch approval when turn prepare omits approval_state" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    alternate_target = create_execution_target!(name: "Alternate target")
    service =
      RunDrafts::ConversationTurnPlanningService.new(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Ship it",
        },
      )
    captured_draft = nil
    service_singleton = class << service; self; end
    lifecycle_singleton = class << AgentRpc::LifecycleCaller; self; end

    service_singleton.alias_method :__test_original_create_draft!, :create_draft!
    service_singleton.define_method(:create_draft!) do
      captured_draft = __test_original_create_draft!
    end

    lifecycle_singleton.alias_method :__test_original_call!, :call!
    lifecycle_singleton.define_method(:call!) do |**_kwargs|
      AgentRpc::KernelServices::ExecutionTargets.propose!(
        draft: captured_draft,
        execution_target_id: alternate_target.id,
      )
      { "prepared_plan" => { "fixture" => true } }
    end

    service.open_and_prepare!

    draft = captured_draft.reload
    assert_equal "awaiting_approval", draft.status
    assert_equal "pending_confirmation", draft.approval_state.fetch("status")
    assert_equal "target_switch", draft.approval_state.fetch("reason")
    assert_equal alternate_target.id, draft.proposed_execution_target_id
    assert_nil draft.materialized_conversation_run_id
  ensure
    if defined?(service_singleton) && service_singleton.method_defined?(:__test_original_create_draft!)
      service_singleton.alias_method :create_draft!, :__test_original_create_draft!
      service_singleton.remove_method :__test_original_create_draft!
    end
    if defined?(lifecycle_singleton) && lifecycle_singleton.method_defined?(:__test_original_call!)
      lifecycle_singleton.alias_method :call!, :__test_original_call!
      lifecycle_singleton.remove_method :__test_original_call!
    end
    server&.shutdown
  end

  test "approval resume keeps the draft permission mode pinned when the live conversation preset changes after parking" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    agent_node =
      conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4").fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    Conversations::RuntimeSettingsUpdater.update!(
      conversation: conversation,
      attributes: { permission_mode: "full_access" },
    )

    assert_enqueued_with(job: DAG::ExecuteNodeJob) do
      conversation.approve_parked_agent_node!(node_id: agent_node.id, approved_by: "manual-approval:test")
    end

    run = draft.reload.materialized_conversation_run
    assert_equal "finalized", draft.status
    assert_equal "approved", draft.approval_state.fetch("status")
    assert_equal "default", run.effective_permission_mode
  ensure
    server&.shutdown
  end

  test "rejected approval discards staged draft mutations and leaves the draft terminal" do
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
      status: "awaiting_approval",
      approval_state: { "status" => "rejected", "reason" => "operator_denied" },
      staged_public_settings_patch: { "tone" => "concise" },
      staged_agent_config_patch: { "mode" => "review" },
      staged_kv_ops: [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal "discarded", draft.reload.status
    assert_equal({}, draft.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
    assert_nil draft.materialized_conversation_run_id
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_nil ConversationKVEntry.find_by(conversation: conversation, key: "shared.stage")

    terminal_error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft.reload) }

    assert_equal "cybros.run_drafts.discarded", terminal_error.code
  ensure
    server&.shutdown
  end

  test "terminal non-approved approval outcomes discard staged draft mutations generically" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    alternate_target = create_execution_target!
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
      status: "awaiting_approval",
      approval_state: { "status" => "denied", "reason" => "operator_denied" },
      proposed_execution_target: alternate_target,
      runtime_governors:
        draft.runtime_governors.deep_merge(
          "execution_capacity" => {
            "scope_type" => "execution_target",
            "execution_target_id" => alternate_target.id,
            "execution_location_id" => alternate_target.execution_location_id,
          },
        ),
      staged_public_settings_patch: { "tone" => "concise" },
      staged_agent_config_patch: { "mode" => "review" },
      staged_kv_ops: [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal "discarded", draft.reload.status
    assert_nil draft.proposed_execution_target_id
    assert_nil draft.runtime_governors["execution_capacity"]
    assert_equal({}, draft.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
  ensure
    server&.shutdown
  end

  test "terminal non-approved approval outcomes reject the parked agent node" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    draft.update!(approval_state: draft.approval_state.merge("status" => "rejected", "reason" => "operator_denied"))

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "operator_denied", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  test "awaiting approval drafts enqueue expiry and expire parked nodes automatically" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = nil
    assert_enqueued_with(job: RunDrafts::ExpireAwaitingApprovalJob) do
      result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    end

    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    travel_to(draft.expires_at + 1.second) do
      perform_enqueued_jobs only: RunDrafts::ExpireAwaitingApprovalJob
    end

    assert_equal "expired", draft.reload.status
    assert_equal "expired", draft.approval_state.fetch("status")
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "approval_expired", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  test "canceling a parked approval discards staged mutations and marks the approval outcome canceled" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    draft.update!(
      staged_public_settings_patch: { "tone" => "concise" },
      staged_agent_config_patch: { "mode" => "review" },
      staged_kv_ops: [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
    )

    conversation.stop_node!(node_id: agent_node.id, reason: "user_cancelled")

    assert_equal DAG::Node::STOPPED, agent_node.reload.state
    assert_equal "discarded", draft.reload.status
    assert_equal "canceled", draft.approval_state.fetch("status")
    assert_equal({}, draft.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
    assert_nil draft.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "conversation approval resumes a parked draft locally and enqueues execution without a second turn prepare" do
    prepare_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            prepare_calls << :called
            base_result.merge(
              "approval_state" => {
                "status" => "pending_confirmation",
                "reason" => "fixture_approval",
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    assert_equal "awaiting_approval", draft.status

    assert_enqueued_with(job: DAG::ExecuteNodeJob) do
      conversation.approve_parked_agent_node!(node_id: agent_node.id, approved_by: "manual-approval:test")
    end

    assert_equal 1, prepare_calls.size
    assert_equal "finalized", draft.reload.status
    assert_equal "approved", draft.approval_state.fetch("status")
    assert draft.materialized_conversation_run_id.present?
  ensure
    server&.shutdown
  end

  test "conversation approval rejects a parked node when the pinned deployment binding has gone stale" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    deployment = runtime.fetch(:deployment)

    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    deployment.update!(status: "inactive", health_status: "inactive", deactivated_at: Time.current)

    error =
      assert_raises(AgentCore::ValidationError) do
        conversation.approve_parked_agent_node!(node_id: agent_node.id, approved_by: "manual-approval:test")
      end

    assert_equal "cybros.run_drafts.stale", error.code
    assert_equal "stale", draft.reload.status
    assert_equal "stale", draft.approval_state.fetch("status")
    assert_equal "binding_stale", draft.approval_state.fetch("reason")
    assert_equal DAG::Node::REJECTED, agent_node.reload.state
    assert_equal "binding_stale", agent_node.metadata.fetch("reason")
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      program = AgentProgram.create!(
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
      deployment =
        AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: server.rpc_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
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
      target = create_execution_target!
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation, deployment: deployment }
    end

    def create_execution_target!(name: "Primary target")
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
          root_path: "/tmp/approval-#{SecureRandom.hex(4)}",
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
