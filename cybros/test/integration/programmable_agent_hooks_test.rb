require "test_helper"

class ProgrammableAgentHooksTest < ActiveSupport::TestCase
  test "planning uses before_agent_step as the canonical run draft hook" do
    observed_payloads = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            observed_payloads << params.deep_dup
            base_result
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Plan it", model_ref: "openai/gpt-5.4")
    draft = RunDraft.order(:created_at).last
    invocation = AgentRPCInvocation.find_by!(scope_type: "run_draft", scope_id: draft.id, method: "before_agent_step")

    assert_equal result.fetch(:agent_node).id, observed_payloads.dig(0, "step", "dag_node_id")
    assert_equal "planning", observed_payloads.dig(0, "step", "phase")
    assert_equal conversation.id, observed_payloads.dig(0, "session_context", "conversation_id")
    assert_equal draft.id, observed_payloads.dig(0, "step", "run_draft_id")
    assert_equal "before_agent_step", invocation.method
    assert_equal ["before_agent_step"], AgentRPCInvocation.where(scope_type: "run_draft", scope_id: draft.id).distinct.order(:method).pluck(:method)
  ensure
    server&.shutdown
  end

  test "planning includes prepared attachment refs in the before_agent_step manifest" do
    observed_payloads = []
    attachment_import_calls = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            observed_payloads << params.deep_dup
            base_result
          end,
          "attachments.import" => lambda do |params, base_result, _identity|
            attachment_import_calls << params.deep_dup
            base_result
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result =
      conversation.append_user_message!(
        content: "Plan it with files",
        model_ref: "openai/gpt-5.4",
        attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
      )
    draft = RunDraft.order(:created_at).last
    attachment_manifest = observed_payloads.dig(0, "attachment_manifest")

    assert_equal result.fetch(:agent_node).id, observed_payloads.dig(0, "step", "dag_node_id")
    assert_equal 1, attachment_import_calls.length
    assert_equal 1, attachment_manifest.length
    assert_equal "attachment_import", attachment_manifest.dig(0, "kind")
    assert_equal "attachment_import", attachment_manifest.dig(0, "prepared_ref", "kind")
    assert_equal "attachment-note.txt", attachment_manifest.dig(0, "filename")
    assert_equal draft.id, RunDraft.order(:created_at).last.id
  ensure
    server&.shutdown
  end

  test "planning stages prompt-buffer mutations from the typed planning envelope" do
    staged_entry_id = SecureRandom.uuid
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "prompt_buffer_ops" => [
                    {
                      "op" => "put",
                      "entry" => {
                        "id" => staged_entry_id,
                        "buffer_name" => "summaries",
                        "seq" => 10,
                        "kind" => "summary",
                        "content" => "typed planning summary",
                        "priority" => 5,
                        "estimated_tokens" => 7,
                        "metadata" => { "source" => "planning" },
                      },
                    },
                  ],
                },
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

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

    draft = RunDraft.order(:created_at).last
    assert_equal "put", draft.staged_prompt_buffer_ops.dig(0, "op")
    assert_equal staged_entry_id, draft.staged_prompt_buffer_ops.dig(0, "entry", "id")
    assert_equal "typed planning summary", draft.staged_prompt_buffer_ops.dig(0, "entry", "content")
  ensure
    server&.shutdown
  end

  test "planning rejects legacy execution_target proposals at the hook contract boundary" do
    alternate_target_id = nil
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "execution_target_proposal" => {
                  "execution_target_id" => alternate_target_id,
                },
              },
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)
    alternate_target_id = SecureRandom.uuid

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

    assert_equal "cybros.programmable_agent.hook_contract.invalid_planning_field", error.code
    assert_nil RunDraft.order(:created_at).last&.planning&.dig("execution_target_proposal")
  ensure
    server&.shutdown
  end

  test "planning validates the returned tool_surface manifest instead of reconstructing it" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            selected_tool_id = params.dig("capability_snapshot", "effective_tools", 0, "effective_tool_id")
            base_result.deep_merge(
              "planning" => {
                "tool_surface" => {
                  "capability_registry_snapshot_id" => params.dig("capability_snapshot", "capability_registry_snapshot_id"),
                  "selected_tool_ids" => [selected_tool_id],
                  "tool_surface_id" => "surface_mismatched",
                  "logical_tool_names" => ["compact_context"],
                },
              },
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

    assert_equal "cybros.programmable_agent.tool_surface_manifest.tool_surface_id_mismatch", error.code
  ensure
    server&.shutdown
  end

  test "planning rejects direct approval_state mutation from before_agent_step" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, _base_result, _identity|
            {
              "planning" => {
                "approval_state" => {
                  "status" => "pending_confirmation",
                },
              },
            }
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

    assert_equal "cybros.programmable_agent.hook_contract.approval_state_forbidden", error.code
  ensure
    server&.shutdown
  end

  test "planning rejects create_task actions during the planning phase" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "actions" => [
                {
                  "type" => "create_task",
                  "logical_tool_name" => "compact_context",
                  "input" => { "reason" => "budget pressure" },
                  "placement" => "append",
                },
              ],
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

    assert_equal "cybros.programmable_agent.hook_policy.create_task_not_allowed", error.code
  ensure
    server&.shutdown
  end

  test "before_agent_step halt discards the draft and stops the current placeholder node" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "planning" => {
                "staged_mutations" => {
                  "kv_ops" => [
                    { "op" => "set", "key" => "shared.plan", "value" => { "status" => "should_not_apply" } },
                  ],
                },
              },
              "actions" => [
                {
                  "type" => "halt",
                  "reason" => "agent_declined_turn",
                  "message" => "Agent declined to continue",
                },
              ],
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Plan it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node).reload
    draft = RunDraft.order(:created_at).last

    assert_equal DAG::Node::STOPPED, agent_node.state
    assert_equal "agent_declined_turn", agent_node.metadata.fetch("reason")
    assert_equal "before_agent_step", agent_node.metadata.fetch("hook_name")
    assert_equal "halt", agent_node.metadata.fetch("action_type")
    assert_equal "Agent declined to continue", agent_node.metadata.fetch("message")
    assert_equal "discarded", draft.reload.status
    assert_nil draft.materialized_conversation_run_id
    assert_equal [], draft.staged_kv_ops
    assert_nil conversation.chat_lane.lane_kv_entries.find_by(key: "shared.plan")
  ensure
    server&.shutdown
  end

  test "before_agent_step set_step_status updates the current placeholder preview" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Processing fixture plan",
                  "state" => "running",
                },
              ],
            )
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server:)
    conversation = runtime.fetch(:conversation)

    result = conversation.append_user_message!(content: "Plan it", model_ref: "openai/gpt-5.4")
    agent_node = result.fetch(:agent_node).reload

    assert_equal "Processing fixture plan", agent_node.body_output_preview.fetch("content")
    assert_equal "Processing fixture plan", conversation.output_preview_for_node_id(agent_node.id).fetch("content")
  ensure
    server&.shutdown
  end

  test "before_agent_step set_step_status rejects missing placeholder nodes" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |_params, base_result, _identity|
            base_result.deep_merge(
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => "Processing fixture plan",
                },
              ],
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

    assert_equal "cybros.programmable_agent.runtime.no_active_step_placeholder", error.code
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      fixture_identity = Cybros::ProgrammableAgentFixture.identity
      supported_methods = fixture_identity.fetch("supported_methods")
      program =
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
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: fixture_identity.fetch("deployment_fingerprint"),
          status: "active",
          health_status: "healthy",
          protocol_version: fixture_identity.fetch("protocol_version"),
          agent_sdk_version: fixture_identity.fetch("agent_sdk_version"),
          supported_methods: supported_methods,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
            "observed_runtime_identity" => {
              "supported_methods" => supported_methods,
            },
          },
          inspection_details: {
            "identity" => {
              "deployment_fingerprint" => fixture_identity.fetch("deployment_fingerprint"),
            },
            "initialize" => {},
            "describe" => {},
            "health" => {},
            "schemas" => {},
          },
          activated_at: Time.current.change(usec: 0),
        )
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
      agent = materialize_agent_runtime!(agent: program)

      conversation = create_conversation!(user: user, title: "Chat", agent: agent)
      conversation.update!(
        permission_mode: "default",
        agent_config_schema_fingerprint: agent.config_schema_fingerprint,
      )

      { agent: agent, conversation: conversation, deployment: deployment, program: program }
    end

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/#{name}"), content_type)
    end
end
