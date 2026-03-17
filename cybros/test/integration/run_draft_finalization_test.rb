require "test_helper"

class RunDraftFinalizationTest < ActiveSupport::TestCase
  test "conversation append_user_message materializes a run from a durable typed planning draft" do
    seen_draft_ids = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            seen_draft_ids << params.dig("step", "run_draft_id")
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
    assert_equal true, draft.planning.dig("step_plan", "fixture")
    assert_equal "fixture_plan_v2", draft.planning.dig("step_plan", "kind")
    assert_equal draft.recognized_deployment_id, run.recognized_deployment_id
    assert_equal draft.recognized_deployment_key, run.recognized_deployment_key
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, draft.runtime_governors.dig("execution_capacity", "scope_id")
    assert_equal "agent", run.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, run.runtime_governors.dig("execution_capacity", "scope_id")
    assert_equal runtime.fetch(:deployment).deployment_fingerprint, run.deployment_fingerprint
    assert_equal "default", run.effective_permission_mode
  ensure
    server&.shutdown
  end

  test "finalization commits staged settings config lane kv and prompt buffer mutations into conversation state" do
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
      staged_prompt_buffer_ops: [{
        "op" => "put",
        "entry" => {
          "id" => SecureRandom.uuid,
          "buffer_name" => "summaries",
          "seq" => 10,
          "kind" => "summary",
          "content" => "Branch-ready summary",
          "priority" => 5,
          "estimated_tokens" => 7,
          "metadata" => { "source" => "prepare" },
        },
      }],
    )

    run = RunDrafts::FinalizeService.finalize!(draft: draft)

    conversation.reload
    assert_equal "concise", conversation.public_settings.fetch("tone")
    assert_equal({ "mode" => "review" }, conversation.selected_agent_config)
    assert_equal({ "status" => "planned" }, LaneKVEntry.find_by!(lane: conversation.chat_lane, key: "shared.stage").value)
    prompt_buffer_entry = LanePromptBufferEntry.find_by!(lane: conversation.chat_lane, buffer_name: "summaries", seq: 10)
    assert_equal "Branch-ready summary", prompt_buffer_entry.content
    assert_equal 7, prompt_buffer_entry.estimated_tokens
    assert_equal({ "source" => "prepare" }, prompt_buffer_entry.metadata)
    assert_equal run.id, draft.reload.materialized_conversation_run_id
    assert_equal "finalized", draft.status
    assert_equal [], draft.staged_prompt_buffer_ops
  ensure
    server&.shutdown
  end

  test "finalization normalizes staged lane kv keys before applying updates" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    LaneKVEntry.create!(
      lane: conversation.chat_lane,
      key: "shared.stage",
      value: { "status" => "old" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
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
      staged_kv_ops: [{ "op" => "set", "key" => " shared.stage ", "value" => { "status" => "planned" } }],
    )

    RunDrafts::FinalizeService.finalize!(draft: draft)

    assert_equal 1, LaneKVEntry.where(lane: conversation.chat_lane, key: "shared.stage").count
    assert_equal({ "status" => "planned" }, LaneKVEntry.find_by!(lane: conversation.chat_lane, key: "shared.stage").value)
  ensure
    server&.shutdown
  end

  test "finalization applies staged lane kv mutations to the active conversation lane only" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    root_conversation = runtime.fetch(:conversation)
    graph = root_conversation.root_graph

    fork_agent = nil
    graph.mutate! do |m|
      fork_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    branch =
      root_conversation.create_child!(
        from_node_id: fork_agent.id,
        kind: "branch",
        title: "Branch",
        user_content: "What if?",
      )

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: branch,
        initiated_by_user: branch.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Ship it",
        },
      )
    draft.update!(
      staged_kv_ops: [{ "op" => "set", "key" => "branch.stage", "value" => { "status" => "planned" } }],
    )

    RunDrafts::FinalizeService.finalize!(draft: draft)

    assert_nil LaneKVEntry.find_by(lane: root_conversation.chat_lane, key: "branch.stage")
    assert_equal({ "status" => "planned" }, LaneKVEntry.find_by!(lane: branch.chat_lane, key: "branch.stage").value)
  ensure
    server&.shutdown
  end

  test "planning snapshots the selected runtime deployment fingerprint onto the draft" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    pinned_deployment = runtime.fetch(:deployment)
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
    draft = service.send(:create_draft!)

    assert_equal runtime.fetch(:agent).id, draft.agent_id
    assert_predicate draft.recognized_deployment_id, :present?
    assert_equal draft.recognized_deployment.recognized_deployment_key, draft.recognized_deployment_key
    assert_equal runtime.fetch(:agent).id, draft.recognized_deployment.agent_id
    assert_equal pinned_deployment.deployment_fingerprint, draft.deployment_fingerprint
  ensure
    server&.shutdown
  end

  test "agent deployment upgrades only affect future turns while historical runs stay pinned to their recognized deployment" do
    primary_server = Cybros::ProgrammableAgentFixture::Server.new.start
    upgraded_server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: { "deployment_fingerprint" => "fixture-deployment-v2" },
      ).start
    runtime = create_programmable_runtime!(server: primary_server)
    conversation = runtime.fetch(:conversation)

    first_draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "First turn before upgrade",
        },
      )
    RunDrafts::FinalizeService.finalize!(draft: first_draft)
    first_run = first_draft.reload.materialized_conversation_run

    upgrade_agent_runtime!(
      agent: runtime.fetch(:agent),
      endpoint_url: upgraded_server.rpc_url,
      deployment_fingerprint: "fixture-deployment-v2",
    )

    second_draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Second turn after upgrade",
        },
      )
    RunDrafts::FinalizeService.finalize!(draft: second_draft)
    second_run = second_draft.reload.materialized_conversation_run

    assert_equal "fixture-deployment-v1", first_run.reload.deployment_fingerprint
    assert_equal "fixture-deployment-v2", second_run.deployment_fingerprint
    assert_equal first_draft.recognized_deployment_id, first_run.recognized_deployment_id
    assert_equal second_draft.recognized_deployment_id, second_run.recognized_deployment_id
    refute_equal first_run.recognized_deployment_id, second_run.recognized_deployment_id
  ensure
    primary_server&.shutdown
    upgraded_server&.shutdown
  end

  test "finalization rejects drafts when the live agent transport retargets in place without changing deployment fingerprint" do
    primary_server = Cybros::ProgrammableAgentFixture::Server.new.start
    replacement_server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server: primary_server)
    conversation = runtime.fetch(:conversation)
    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Retarget me",
        },
      )

    runtime.fetch(:agent).update!(endpoint_url: replacement_server.rpc_url)

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", error.code
    assert_nil draft.reload.materialized_conversation_run_id
    assert_equal 0, ConversationRun.where(conversation: conversation).count
  ensure
    primary_server&.shutdown
    replacement_server&.shutdown
  end

  test "finalization rejects drafts that have not completed planning" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    dag_node_id = SecureRandom.uuid
    draft =
      build_open_draft!(
        conversation: conversation,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => dag_node_id,
          "user_input" => "Still planning",
        },
      )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.not_prepared", error.code
    assert_equal "open", draft.reload.status
    assert_equal 0, ConversationRun.where(conversation: conversation, dag_node_id: dag_node_id).count
  ensure
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
    upgrade_agent_runtime!(
      agent: runtime.fetch(:agent),
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

  test "finalization fails stale when provider governor facts drift before materialization" do
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
    draft.provider_credential.update!(requests_per_minute: draft.provider_credential.requests_per_minute + 1)

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", error.code
    assert_equal({}, conversation.reload.public_settings)
    assert_equal "stale", draft.reload.status
    assert_nil draft.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "finalization fails stale when execution capacity facts drift before materialization" do
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
    runtime.fetch(:agent).update!(
      max_concurrent_tasks: 2,
      max_queued_tasks: 5,
      default_timeout_s: 600,
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", error.code
    assert_equal({}, conversation.reload.public_settings)
    assert_equal "stale", draft.reload.status
    assert_nil draft.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "planning stages typed mutations on the draft and commits them only at finalization" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "public_settings_patch" => { "tone" => "concise" },
                  "agent_config_patch" => { "mode" => "review" },
                  "kv_ops" => [
                    { "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } },
                  ],
                },
              },
            )
          end,
        },
      ).start
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
          "user_input" => "Plan it",
        },
      )

    assert_equal({ "tone" => "concise" }, draft.reload.staged_public_settings_patch)
    assert_equal({ "mode" => "review" }, draft.staged_agent_config_patch)
    assert_equal(
      [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
      draft.staged_kv_ops,
    )
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_nil LaneKVEntry.find_by(lane: conversation.chat_lane, key: "shared.stage")

    run = RunDrafts::FinalizeService.finalize!(draft: draft)

    conversation.reload
    assert_equal "concise", conversation.public_settings.fetch("tone")
    assert_equal({ "mode" => "review" }, conversation.selected_agent_config)
    assert_equal({ "status" => "planned" }, LaneKVEntry.find_by!(lane: conversation.chat_lane, key: "shared.stage").value)
    assert_equal run.id, draft.reload.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "conservative mode parks for approval when planning stages a public settings mutation without an approval request" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "public_settings_patch" => { "tone" => "concise" },
                },
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:, permission_mode: "conservative")
    conversation = runtime.fetch(:conversation)

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )

    assert_equal "awaiting_approval", draft.reload.status
    assert_equal "pending_confirmation", draft.approval_state.fetch("status")
    assert_equal "public_state_mutation", draft.approval_state.fetch("reason")
    assert_equal "conversation.settings.update", draft.approval_state.fetch("method_name")
    assert_equal({ "tone" => "concise" }, draft.staged_public_settings_patch)
    assert_equal({}, conversation.reload.public_settings)
  ensure
    server&.shutdown
  end

  test "default mode allows typed public settings mutations without parking the draft" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "public_settings_patch" => { "tone" => "concise" },
                },
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:, permission_mode: "default")
    conversation = runtime.fetch(:conversation)

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )

    assert_equal "prepared", draft.reload.status
    assert_equal({ "status" => "not_required" }, draft.approval_state)
    assert_equal({ "tone" => "concise" }, draft.staged_public_settings_patch)
    assert_equal({}, conversation.reload.public_settings)
  ensure
    server&.shutdown
  end

  test "conservative mode parks for approval when planning stages a lane kv mutation" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "kv_ops" => [
                    { "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } },
                  ],
                },
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:, permission_mode: "conservative")
    conversation = runtime.fetch(:conversation)

    draft =
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )

    assert_equal "awaiting_approval", draft.reload.status
    assert_equal "public_state_mutation", draft.approval_state.fetch("reason")
    assert_equal "lane.kv.set", draft.approval_state.fetch("method_name")
    assert_equal [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }], draft.staged_kv_ops
  ensure
    server&.shutdown
  end

  test "planning params read the draft-selected agent config after the live conversation selection changes" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    alternate_program = create_program!
    active_deployment!(program: alternate_program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")
    alternate_agent = materialize_agent_runtime!(agent: alternate_program, execution_profile: runtime.fetch(:target))
    conversation.update!(
      agent_config: {
        original_program.config_namespace => { "mode" => "review" },
        alternate_program.config_namespace => { "mode" => "alternate" },
      },
      agent_config_schema_fingerprint: original_program.config_schema_fingerprint,
    )
    draft =
      build_open_draft!(
        conversation: conversation,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )
    conversation.update!(
      agent: alternate_agent,
      agent_config_schema_fingerprint: alternate_agent.config_schema_fingerprint,
    )
    live_conversation = Conversation.find(conversation.id)
    service =
      RunDrafts::ConversationTurnPlanningService.new(
        conversation: live_conversation,
        initiated_by_user: live_conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: draft.trigger_snapshot,
      )

    assert_equal runtime.fetch(:agent).id, draft.agent_id
    assert_equal alternate_agent.id, live_conversation.agent_id
    assert_equal({ "mode" => "alternate" }, live_conversation.selected_agent_config)
    assert_equal(
      { "mode" => "review" },
      service.send(:prepare_params, draft).fetch("agent_config"),
    )
  ensure
    server&.shutdown
  end

  test "conversation config get reads the draft-selected agent namespace after the live conversation selection changes" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    alternate_program = create_program!
    active_deployment!(program: alternate_program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")
    alternate_agent = materialize_agent_runtime!(agent: alternate_program, execution_profile: runtime.fetch(:target))
    conversation.update!(
      agent_config: {
        original_program.config_namespace => { "mode" => "review" },
        alternate_program.config_namespace => { "mode" => "alternate" },
      },
      agent_config_schema_fingerprint: original_program.config_schema_fingerprint,
    )
    draft =
      build_open_draft!(
        conversation: conversation,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => "Plan it",
        },
      )

    conversation.update!(
      agent: alternate_agent,
      agent_config_schema_fingerprint: alternate_agent.config_schema_fingerprint,
    )
    live_conversation = Conversation.find(conversation.id)
    draft_for_read = Struct.new(:bound_conversation, :agent).new(live_conversation, runtime.fetch(:agent))

    assert_equal alternate_agent.id, live_conversation.agent_id
    assert_equal({ "mode" => "alternate" }, live_conversation.selected_agent_config)
    assert_equal(
      { "config" => { "mode" => "review" } },
      AgentRPC::KernelServices::ConversationConfig.get(draft: draft_for_read),
    )
  ensure
    server&.shutdown
  end

  test "planning rejects legacy staged mutation payloads returned outside the typed planning envelope" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "staged_public_settings_patch" => { "tone" => "concise" },
              "staged_agent_config_patch" => { "mode" => "review" },
              "staged_kv_ops" => [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    error =
      assert_raises(AgentCore::ValidationError) do
        RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
          conversation: conversation,
          initiated_by_user: conversation.user,
          selected_model_ref: "openai/gpt-5.4",
          trigger_snapshot: {
            "kind" => "user_turn",
            "dag_node_id" => SecureRandom.uuid,
            "user_input" => "Plan it",
          },
        )
      end

    assert_equal "cybros.programmable_agent.hook_contract.unknown_top_level_key", error.code
  ensure
    server&.shutdown
  end

  test "stale finalization discards staged mutations and remains terminal after bindings change again" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    program = runtime.fetch(:program)
    pinned_deployment = runtime.fetch(:deployment)
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
    pinned_deployment.update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    upgrade_agent_runtime!(
      agent: runtime.fetch(:agent),
      endpoint_url: server.rpc_url,
      deployment_fingerprint: "deployment:v2",
    )

    first_error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", first_error.code
    assert_equal "stale", draft.reload.status
    assert_equal({}, draft.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_nil LaneKVEntry.find_by(lane: conversation.chat_lane, key: "shared.stage")

    upgrade_agent_runtime!(
      agent: runtime.fetch(:agent),
      endpoint_url: server.rpc_url,
      deployment_fingerprint: pinned_deployment.deployment_fingerprint,
    )

    second_error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft.reload) }

    assert_equal "cybros.run_drafts.stale", second_error.code
    assert_nil draft.reload.materialized_conversation_run_id
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
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: deployment)
      ensure_active_openai_credential!
      conversation =
        create_conversation!(
          user: user,
          title: "Chat",
          agent: agent,
        )
      conversation.update!(
        permission_mode: permission_mode,
        agent_config_schema_fingerprint: agent.config_schema_fingerprint,
      )

      {
        agent: agent,
        conversation: conversation,
        deployment: deployment,
        program: program,
        recognized_deployment: recognized_deployment,
        target: target,
      }
    end

    def build_open_draft!(conversation:, selected_model_ref:, trigger_snapshot:)
      resolved =
        RuntimeGovernance::DraftGovernorResolver.resolve!(
          entrypoint: conversation,
          selected_model_ref: selected_model_ref,
        )
      deployment = conversation.agent.active_healthy_deployment_for_published_contract
      recognized_deployment = RecognizedDeployment.recognize!(agent: conversation.agent, deployment: deployment)

      RunDraft.create!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        status: "open",
        permission_mode: resolved.fetch(:permission_mode),
        trigger_snapshot: trigger_snapshot,
        agent: conversation.agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        contract_fingerprint: conversation.agent.published_contract_fingerprint,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at&.change(usec: 0),
        agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
        provider_credential: resolved.fetch(:provider_credential),
        selected_model_ref: resolved.fetch(:selected_model_ref),
        runtime_governors: resolved.fetch(:runtime_governors),
        prepare_invocation_id: SecureRandom.uuid,
        planning: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        staged_prompt_buffer_ops: [],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      )
    end

    def create_program!
      create_agent_record!(
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
    end

    def active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
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
    end

    def replacement_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      active_deployment!(program:, endpoint_url:, deployment_fingerprint:)
    end

    def inactive_deployment!(program:, endpoint_url:, deployment_fingerprint:)
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: "inactive",
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

    def upgrade_agent_runtime!(agent:, endpoint_url:, deployment_fingerprint:, agent_sdk_version: "fixture-ruby-sdk/1.0")
      activated_at = 1.second.from_now.change(usec: 0)
      agent.update!(
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        deployment_fingerprint: deployment_fingerprint,
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: agent_sdk_version,
        supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
        capability_snapshot: {},
        inspection_details: {},
        activated_at: activated_at,
        deactivated_at: nil,
        last_health_checked_at: activated_at,
        last_inspected_at: activated_at,
      )
    end
end
