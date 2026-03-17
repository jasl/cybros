require "test_helper"

class BootstrapHookContractTest < ActiveSupport::TestCase
  test "bootstrap hooks round-trip typed append-only authority task envelopes" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start
    runtime = create_programmable_runtime!(server:)

    envelope =
      Cybros::ProgrammableAgent::HookCaller.call!(
        deployment: runtime.fetch(:deployment),
        conversation: runtime.fetch(:conversation),
        scope_type: "conversation",
        scope_id: runtime.fetch(:conversation).id,
        hook_name: "on_conversation_created",
        invocation_id: "conversation:#{runtime.fetch(:conversation).id}:on_conversation_created",
        request_payload: {
          "conversation_id" => runtime.fetch(:conversation).id,
          "lane_id" => runtime.fetch(:conversation).chat_lane.id,
        },
        allowed_callback_methods: [],
      )

    assert_nil envelope.planning
    assert_equal "create_task", envelope.actions.sole.type
    assert_equal "cybros_seed_message", envelope.actions.sole.logical_tool_name
    assert_equal "append", envelope.actions.sole.placement
  ensure
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
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
      conversation = create_conversation!(user: user, title: "Chat")
      agent = create_agent_runtime!(agent: program, execution_profile: build_default_execution_profile!, deployment: deployment)
      conversation.update!(
        agent: agent,
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )

      { agent: agent, conversation: conversation, deployment: deployment }
    end
end
