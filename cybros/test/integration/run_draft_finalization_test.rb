require "test_helper"
require "net/http"
require "rackup/handler/webrick"

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
    draft.proposed_execution_target.update!(
      max_concurrent_tasks_override: 2,
      max_queued_tasks_override: 5,
      default_timeout_s_override: 600,
    )

    error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", error.code
    assert_equal({}, conversation.reload.public_settings)
    assert_equal "stale", draft.reload.status
    assert_nil draft.materialized_conversation_run_id
  ensure
    server&.shutdown
  end

  test "planning stages callback mutations on the draft and commits them only at finalization" do
    callback_server = CallbackAppServer.new.start
    original_url_options = ActionMailer::Base.default_url_options.dup
    ActionMailer::Base.default_url_options = { host: callback_server.host, port: callback_server.port, protocol: "http" }
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            callback = params.fetch("callback_session")
            fixture_callback!(
              callback: callback,
              method_name: "conversation.settings.update",
              params: {
                "operation_id" => "op-settings",
                "patch" => { "tone" => "concise" },
              },
            )
            fixture_callback!(
              callback: callback,
              method_name: "conversation.config.update",
              params: {
                "operation_id" => "op-config",
                "patch" => { "mode" => "review" },
              },
            )
            fixture_callback!(
              callback: callback,
              method_name: "lane.kv.set",
              params: {
                "operation_id" => "op-kv",
                "key" => "shared.stage",
                "value" => { "status" => "planned" },
              },
            )
            base_result
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
    ActionMailer::Base.default_url_options = original_url_options if defined?(original_url_options)
    server&.shutdown
    callback_server&.shutdown
  end

  test "conservative mode parks for approval when a callback stages public settings mutation without agent approval_state" do
    callback_server = CallbackAppServer.new.start
    original_url_options = ActionMailer::Base.default_url_options.dup
    ActionMailer::Base.default_url_options = { host: callback_server.host, port: callback_server.port, protocol: "http" }
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            fixture_callback!(
              callback: params.fetch("callback_session"),
              method_name: "conversation.settings.update",
              params: {
                "operation_id" => "op-settings-confirm",
                "patch" => { "tone" => "concise" },
              },
            )
            base_result
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
    ActionMailer::Base.default_url_options = original_url_options if defined?(original_url_options)
    server&.shutdown
    callback_server&.shutdown
  end

  test "default mode allows staged public settings mutation without parking the draft" do
    callback_server = CallbackAppServer.new.start
    original_url_options = ActionMailer::Base.default_url_options.dup
    ActionMailer::Base.default_url_options = { host: callback_server.host, port: callback_server.port, protocol: "http" }
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            fixture_callback!(
              callback: params.fetch("callback_session"),
              method_name: "conversation.settings.update",
              params: {
                "operation_id" => "op-settings-allow",
                "patch" => { "tone" => "concise" },
              },
            )
            base_result
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
    ActionMailer::Base.default_url_options = original_url_options if defined?(original_url_options)
    server&.shutdown
    callback_server&.shutdown
  end

  test "replayed conservative kv mutation callbacks do not append duplicate staged operations" do
    callback_server = CallbackAppServer.new.start
    original_url_options = ActionMailer::Base.default_url_options.dup
    ActionMailer::Base.default_url_options = { host: callback_server.host, port: callback_server.port, protocol: "http" }
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |params, base_result, _identity|
            callback = params.fetch("callback_session")
            2.times do
              fixture_callback!(
                callback: callback,
                method_name: "lane.kv.set",
                params: {
                  "operation_id" => "op-kv-confirm",
                  "key" => "shared.stage",
                  "value" => { "status" => "planned" },
                },
              )
            end
            base_result
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
    assert_equal [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }], draft.staged_kv_ops
  ensure
    ActionMailer::Base.default_url_options = original_url_options if defined?(original_url_options)
    server&.shutdown
    callback_server&.shutdown
  end

  test "planning params read the draft-selected program config after the live conversation selection changes" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    alternate_program = create_program!
    active_deployment!(program: alternate_program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")
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
      agent_program: alternate_program,
      agent_config_schema_fingerprint: alternate_program.config_schema_fingerprint,
    )
    live_conversation = Conversation.find(conversation.id)
    service =
      RunDrafts::ConversationTurnPlanningService.new(
        conversation: live_conversation,
        initiated_by_user: live_conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: draft.trigger_snapshot,
      )

    assert_equal original_program.id, draft.agent_program_id
    assert_equal alternate_program.id, live_conversation.agent_program_id
    assert_equal({ "mode" => "alternate" }, live_conversation.selected_agent_config)
    assert_equal(
      { "mode" => "review" },
      service.send(:prepare_params, draft).fetch("agent_config"),
    )
  ensure
    server&.shutdown
  end

  test "conversation config get reads the draft-selected program namespace after the live conversation selection changes" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    original_program = runtime.fetch(:program)
    alternate_program = create_program!
    active_deployment!(program: alternate_program, endpoint_url: server.rpc_url, deployment_fingerprint: "fixture-deployment-v2")
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
      agent_program: alternate_program,
      agent_config_schema_fingerprint: alternate_program.config_schema_fingerprint,
    )
    live_conversation = Conversation.find(conversation.id)
    draft_for_read = Struct.new(:bound_conversation, :agent_program).new(live_conversation, original_program)

    assert_equal alternate_program.id, live_conversation.agent_program_id
    assert_equal({ "mode" => "alternate" }, live_conversation.selected_agent_config)
    assert_equal(
      { "config" => { "mode" => "review" } },
      AgentRPC::KernelServices::ConversationConfig.get(draft: draft_for_read),
    )
  ensure
    server&.shutdown
  end

  test "planning ignores direct staged mutation payloads returned by turn prepare" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "turn.prepare" => lambda do |_params, base_result, _identity|
            base_result.merge(
              "staged_public_settings_patch" => { "tone" => "concise" },
              "staged_agent_config_patch" => { "mode" => "review" },
              "staged_kv_ops" => [{ "op" => "set", "key" => "shared.stage", "value" => { "status" => "planned" } }],
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

    assert_equal({}, draft.reload.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_nil LaneKVEntry.find_by(lane: conversation.chat_lane, key: "shared.stage")
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
    replacement = replacement_deployment!(program:, endpoint_url: server.rpc_url, deployment_fingerprint: "deployment:v2")

    first_error = assert_raises(AgentCore::ValidationError) { RunDrafts::FinalizeService.finalize!(draft: draft) }

    assert_equal "cybros.run_drafts.stale", first_error.code
    assert_equal "stale", draft.reload.status
    assert_equal({}, draft.staged_public_settings_patch)
    assert_equal({}, draft.staged_agent_config_patch)
    assert_equal([], draft.staged_kv_ops)
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_nil LaneKVEntry.find_by(lane: conversation.chat_lane, key: "shared.stage")

    replacement.update!(status: "inactive", deactivated_at: Time.current.change(usec: 0))
    pinned_deployment.update!(status: "active", health_status: "healthy", deactivated_at: nil)

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

    class CallbackAppServer
      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 0)
        @host = host
        @port = Integer(port)
      end

      def start
        return self if @webrick_server

        @webrick_server =
          Rackup::Handler::WEBrick::Server.new(
            Rails.application,
            BindAddress: host,
            Port: port,
            AccessLog: [],
            Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
            StartCallback: -> { @ready = true },
          )
        @thread = Thread.new { @webrick_server.start }
        wait_until_ready!
        @port = @webrick_server.config.fetch(:Port)
        self
      end

      def shutdown
        @webrick_server&.shutdown
        @thread&.join(1.0)
      ensure
        @webrick_server = nil
        @thread = nil
        @ready = false
      end

      private

        def wait_until_ready!
          40.times do
            return if @ready

            sleep 0.05
          end

          raise "callback app server did not become ready"
        end
    end

    def fixture_callback!(callback:, method_name:, params:)
      uri = URI(callback.fetch("endpoint"))
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{callback.fetch("bearer")}"
      request.body = JSON.generate({
        "jsonrpc" => "2.0",
        "id" => SecureRandom.uuid,
        "method" => method_name,
        "params" => params,
      })

      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      raise "callback #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      if payload["error"].present?
        raise "callback error: #{payload.fetch("error").inspect}"
      end

      payload.fetch("result")
    end

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

    def build_open_draft!(conversation:, selected_model_ref:, trigger_snapshot:)
      resolved =
        RuntimeGovernance::DraftGovernorResolver.resolve!(
          entrypoint: conversation,
          selected_model_ref: selected_model_ref,
        )
      deployment = conversation.agent_program.active_healthy_deployment

      RunDraft.create!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        status: "open",
        permission_mode: resolved.fetch(:permission_mode),
        trigger_snapshot: trigger_snapshot,
        agent_program: conversation.agent_program,
        contract_fingerprint: conversation.agent_program.published_contract_fingerprint,
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at&.change(usec: 0),
        agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
        provider_credential: resolved.fetch(:provider_credential),
        proposed_execution_target: resolved.fetch(:proposed_execution_target),
        selected_model_ref: resolved.fetch(:selected_model_ref),
        runtime_governors: resolved.fetch(:runtime_governors),
        prepare_invocation_id: SecureRandom.uuid,
        prepared_plan: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      )
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
