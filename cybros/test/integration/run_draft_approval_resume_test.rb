require "test_helper"

class RunDraftApprovalResumeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "approval park marks the agent node awaiting approval and resume finalizes without a second before_agent_step" do
    prepare_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            prepare_calls << :called
            base_result.deep_merge(
              "planning" => {
                "approval_request" => {
                  "status" => "pending_confirmation",
                  "reason" => "target_switch",
                },
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
    assert_equal true, draft.planning.dig("step_plan", "fixture")
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

  test "approval resume keeps the draft permission mode pinned when the live conversation preset changes after parking" do
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

  test "approval resume keeps the draft agent config schema fingerprint pinned when the live conversation agent changes after parking" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    agent_node =
      conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4").fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    alternate_program = create_program!(name: "Alternate Program", config_namespace: "fixture.program.alt", server:)
    alternate_agent =
      create_agent_runtime!(
        agent: alternate_program,
        execution_profile: build_default_execution_profile!,
      )

    Conversations::RuntimeSettingsUpdater.update!(
      conversation: conversation,
      attributes: { agent_id: alternate_agent.id },
    )

    assert_enqueued_with(job: DAG::ExecuteNodeJob) do
      conversation.approve_parked_agent_node!(node_id: agent_node.id, approved_by: "manual-approval:test")
    end

    run = draft.reload.materialized_conversation_run
    assert_equal "finalized", draft.status
    assert_equal runtime.fetch(:agent).id, run.agent_id
    assert_equal original_program.config_schema_fingerprint, run.agent_config_schema_fingerprint
    assert_equal original_program.config_schema_fingerprint, draft.agent_config_schema_fingerprint
    assert_equal alternate_program.config_schema_fingerprint, conversation.reload.agent_config_schema_fingerprint
  ensure
    server&.shutdown
  end

  test "approval resume keeps the live conversation schema on the current agent when staged config mutations finalize an older parked draft" do
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    agent_node =
      conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4").fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    alternate_program = create_program!(name: "Alternate Program", config_namespace: "fixture.program.alt", server:)
    alternate_agent =
      create_agent_runtime!(
        agent: alternate_program,
        execution_profile: build_default_execution_profile!,
      )

    draft.update!(staged_agent_config_patch: { "mode" => "review" })
    Conversations::RuntimeSettingsUpdater.update!(
      conversation: conversation,
      attributes: { agent_id: alternate_agent.id },
    )

    assert_enqueued_with(job: DAG::ExecuteNodeJob) do
      conversation.approve_parked_agent_node!(node_id: agent_node.id, approved_by: "manual-approval:test")
    end

    run = draft.reload.materialized_conversation_run
    assert_equal original_program.config_schema_fingerprint, run.agent_config_schema_fingerprint
    assert_equal alternate_program.config_schema_fingerprint, conversation.reload.agent_config_schema_fingerprint
    assert_equal({ "mode" => "review" }, conversation.reload.agent_config.fetch(original_program.config_namespace))
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
    assert_nil LaneKVEntry.find_by(lane: conversation.chat_lane, key: "shared.stage")

    terminal_error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft.reload) }

    assert_equal "cybros.run_drafts.discarded", terminal_error.code
  ensure
    server&.shutdown
  end

  test "terminal non-approved approval outcomes discard staged draft mutations generically" do
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
      approval_state: { "status" => "denied", "reason" => "operator_denied" },
      staged_public_settings_patch: { "tone" => "concise" },
      staged_agent_config_patch: { "mode" => "review" },
      staged_kv_ops: [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
    )
    expected_recognized_deployment_key = draft.recognized_deployment_key

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::ApprovalResumeService.resume!(draft: draft) }

    assert_equal "cybros.run_drafts.approval_not_granted", error.code
    assert_equal "discarded", draft.reload.status
    assert_equal expected_recognized_deployment_key, draft.recognized_deployment_key
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal conversation.agent_id, draft.runtime_governors.dig("execution_capacity", "scope_id")
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

  test "conversation approval resumes a parked draft locally and enqueues execution without a second before_agent_step" do
    prepare_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            prepare_calls << :called
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
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    deployment = runtime.fetch(:deployment)

    result = conversation.append_user_message!(content: "Ship it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last

    deployment.update!(status: "inactive", health_status: "unhealthy", deactivated_at: Time.current)
    runtime.fetch(:agent).update!(status: "inactive", health_status: "unhealthy", deactivated_at: Time.current)

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
      program = create_agent_record!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      target = create_execution_target!
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Chat")
      agent = create_agent_runtime!(agent: program, execution_profile: target, deployment: deployment)
      conversation.update!(
        agent: agent,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { agent: agent, conversation: conversation, deployment: deployment, program: program }
    end

    def create_program!(name:, config_namespace:, server:)
      program =
        create_agent_record!(
          name: name,
          config_namespace: config_namespace,
          published_contract_fingerprint: "contract:#{config_namespace}",
          manifest_snapshot: {
            "agent_key" => config_namespace.tr(".", "-"),
            "name" => name,
          },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:#{config_namespace}",
        )
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: server.rpc_url,
        deployment_bearer_secret_ref: "secret://#{config_namespace}",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{config_namespace}",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
      program
    end

    def create_execution_target!(name: "Primary target")
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
          root_path: "/tmp/approval-#{SecureRandom.hex(4)}",
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
