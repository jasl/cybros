require "test_helper"

class AgentUpgradeConversationBindingTest < ActiveSupport::TestCase
  test "upgrading a bound agent only affects future turns while historical runs stay pinned" do
    primary_server = fixture_server!.start
    upgraded_server =
      fixture_server!(
        identity_overrides: {
          "deployment_fingerprint" => "fixture-deployment-v2",
          "agent_sdk_version" => "fixture-ruby-sdk/2.0",
        },
      ).start
    runtime = create_programmable_runtime!(server: primary_server)
    conversation = runtime.fetch(:conversation)
    agent = runtime.fetch(:agent)

    first_draft = plan_turn!(conversation: conversation, user_input: "First turn before upgrade")
    first_run = RunDrafts::FinalizeService.finalize!(draft: first_draft)

    upgraded_at = 1.second.from_now.change(usec: 0)
    agent.update!(
      endpoint_url: upgraded_server.rpc_url,
      deployment_fingerprint: "fixture-deployment-v2",
      agent_sdk_version: "fixture-ruby-sdk/2.0",
      activated_at: upgraded_at,
      last_health_checked_at: upgraded_at,
      last_inspected_at: upgraded_at,
    )

    second_draft = plan_turn!(conversation: conversation.reload, user_input: "Second turn after upgrade")
    second_run = RunDrafts::FinalizeService.finalize!(draft: second_draft)

    assert_equal agent.id, conversation.reload.agent_id
    assert_equal first_draft.recognized_deployment_key, first_run.reload.recognized_deployment_key
    assert_equal second_draft.reload.recognized_deployment_id, second_run.reload.recognized_deployment_id
    assert_equal second_draft.reload.recognized_deployment_key, second_run.reload.recognized_deployment_key
    refute_equal first_run.reload.recognized_deployment_key, second_run.reload.recognized_deployment_key
  ensure
    primary_server&.shutdown
    upgraded_server&.shutdown
  end

  private

    def fixture_server!(identity_overrides: {})
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        identity_overrides: identity_overrides,
      )
    end

    def create_programmable_runtime!(server:)
      user = create_user!
      agent =
        create_agent!(
          name: "Fixture Agent",
          config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          config_schema_fingerprint: "config:v1",
          manifest_snapshot: { "name" => "Fixture Agent", "agent_program_key" => "fixture-program" },
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Cybros::ProgrammableAgentFixture.identity.fetch("supported_methods"),
          activated_at: Time.current.change(usec: 0),
          last_health_checked_at: Time.current.change(usec: 0),
          last_inspected_at: Time.current.change(usec: 0),
        )
      recognized_deployment = recognize_agent_runtime!(agent: agent)
      ensure_active_openai_credential!
      conversation = create_conversation!(user: user, title: "Upgrade audit", agent: agent)
      conversation.update!(agent_config_schema_fingerprint: agent.config_schema_fingerprint)

      {
        agent: agent,
        conversation: conversation,
        recognized_deployment: recognized_deployment,
      }
    end

    def plan_turn!(conversation:, user_input:)
      RunDrafts::ConversationTurnPlanningService.open_and_prepare!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        selected_model_ref: "openai/gpt-5.4",
        trigger_snapshot: {
          "kind" => "user_turn",
          "dag_node_id" => SecureRandom.uuid,
          "user_input" => user_input,
        },
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
