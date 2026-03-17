require "test_helper"

class ConversationBootstrapDispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    @workspace_root = Dir.mktmpdir("cybros-conversation-bootstrap-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  test "conversation bootstrap materializes the workspace under the agent root before the first main-lane user message" do
    conversation = nil

    with_default_agent_workspace_root(@workspace_root) do
      conversation =
        create_conversation!(
          title: "Conversation",
          metadata: { "agent" => { "key" => "main", "agent_profile" => "coding" } },
        )

      conversation.reload
      assert_predicate conversation.workspace_root_path, :directory?
      assert_predicate conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id), :directory?
      assert_equal Pathname.new(@workspace_root).join("bundled", "claw", "conversations", conversation.id).cleanpath, conversation.workspace_root_path

      first_path = conversation.workspace_root_path
      first_lane_path = conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id)

      conversation.append_user_message!(content: "Initialize the workspace")

      conversation.reload
      assert_equal first_path, conversation.workspace_root_path
      assert_equal first_lane_path, conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id)

      conversation.append_user_message!(content: "Keep the same workspace")

      conversation.reload
      assert_equal first_path, conversation.workspace_root_path
      assert_equal first_lane_path, conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id)
    end
  end

  test "lane-first-user bootstrap uses the selected agent deployment even when legacy conversation bindings are stale" do
    observed_payloads = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "on_lane_first_user_message" => lambda do |params, base_result, _identity|
            observed_payloads << params.deep_dup
            base_result
          end,
        },
      ).start
    runtime = create_programmable_runtime!(server: server)
    conversation = create_conversation!(title: "Conversation")

    conversation.update!(
      agent: runtime.fetch(:agent),
      agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
    )

    assert_equal runtime.fetch(:agent).id, conversation.agent_id
    assert_equal runtime.fetch(:agent).config_schema_fingerprint, conversation.agent_config_schema_fingerprint

    user_node = nil
    conversation.root_graph.mutate! do |m|
      user_node =
        m.create_node(
          lane: conversation.chat_lane,
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Use the selected runtime",
          metadata: {},
        )
    end

    Conversations::BootstrapHookDispatcher.dispatch_lane_first_user_message!(
      conversation: conversation,
      user_node: user_node,
      anchor_node: user_node,
    )

    invocation =
      AgentRPCInvocation.where(
        scope_type: "conversation",
        scope_id: conversation.id,
        method: "on_lane_first_user_message",
      ).order(:created_at).last

    assert_equal runtime.fetch(:agent).id, invocation.agent_id
    assert_equal conversation.id, observed_payloads.dig(0, "conversation_id")
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
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
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      inspect_agent_runtime!(agent: deployment)
      agent = materialize_agent_runtime!(program: program)

      { agent: agent, deployment: deployment, program: program }
    end
end
