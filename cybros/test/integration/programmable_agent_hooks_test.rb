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
      program =
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
      location =
        ExecutionLocation.create!(
          name: "Primary host",
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
          name: "Primary workspace",
          root_path: "/tmp/programmable-hooks-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: "Primary target",
          status: "active",
          sandboxed: true,
        )

      conversation = create_conversation!(user: user, title: "Chat")
      conversation.update!(
        agent_program: program,
        default_execution_target: target,
        permission_mode: "default",
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { conversation: conversation, deployment: deployment, program: program }
    end
end
