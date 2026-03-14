require "application_system_test_case"

class SystemSettingsRuntimeGovernanceSystemTest < ApplicationSystemTestCase
  teardown do
    destroy_created_runtime_governance_records!
  end

  test "operator can review parked waits and recent runtime outcomes in the browser" do
    owner = track_record(create_user!(email: "owner-runtime-governance@example.com"))
    track_record(owner.identity)
    provider_credential = create_provider_credential!(provider_key: "browser-provider")
    create_provider_wait!(provider_credential: provider_credential)
    execution_wait_agent = create_execution_wait!
    denied_agent = create_execution_denial!
    create_deployment_with_backoff!

    sign_in_as!(email: owner.identity.email)
    visit system_settings_runtime_governance_path

    assert_text "Runtime Governance"
    assert_text "Current parked waits"
    assert_text(/Provider limit/i)
    assert_text(/Execution capacity/i)
    assert_text(/Deployment backoff/i)
    assert_text "browser-provider"
    assert_text execution_wait_agent.name
    assert_text denied_agent.name
    assert_text "execution_capacity_denied"
  end

  private

    def destroy_created_runtime_governance_records!
      Array(@tracked_runtime_waits).reverse_each(&:destroy!)
      Array(@tracked_provider_budget_reservations).reverse_each(&:destroy!)
      Array(@tracked_execution_capacity_leases).reverse_each(&:destroy!)
      Array(@tracked_conversation_runs).reverse_each(&:destroy!)
      Array(@tracked_recognized_deployments).reverse_each(&:destroy!)
      Array(@tracked_conversations).reverse_each(&:destroy!)
      Agent.where(id: Array(@tracked_agents).map(&:id)).delete_all
      Array(@tracked_llm_provider_credentials).reverse_each(&:destroy!)
      Array(@tracked_users).reverse_each(&:destroy!)
      Array(@tracked_identities).reverse_each(&:destroy!)
    end

    def track_record(record)
      case record
      when RuntimeWait
        (@tracked_runtime_waits ||= []) << record
      when ProviderBudgetReservation
        (@tracked_provider_budget_reservations ||= []) << record
      when ExecutionCapacityLease
        (@tracked_execution_capacity_leases ||= []) << record
      when ConversationRun
        (@tracked_conversation_runs ||= []) << record
      when RecognizedDeployment
        (@tracked_recognized_deployments ||= []) << record
      when Conversation
        (@tracked_conversations ||= []) << record
      when Agent
        (@tracked_agents ||= []) << record
      when LLMProviderCredential
        (@tracked_llm_provider_credentials ||= []) << record
      when User
        (@tracked_users ||= []) << record
      when Identity
        (@tracked_identities ||= []) << record
      end

      record
    end

    def create_provider_wait!(provider_credential:)
      track_record(
        RuntimeGovernance::RuntimeWaits.park!(
          owner_type: "RunDraft",
          owner_id: SecureRandom.uuid,
          reason_type: "provider_limit",
          subject_type: "llm_provider_credential",
          subject_id: provider_credential.id,
          retry_at: 5.minutes.from_now.change(usec: 0),
          details: { "provider_request_id" => "browser-provider-wait" },
        ),
      )
    end

    def create_execution_wait!
      program = create_program!(name: "Browser execution wait")
      agent = track_record(materialize_agent_runtime!(program: program))

      track_record(
        RuntimeGovernance::RuntimeWaits.park!(
          owner_type: "ConversationRun",
          owner_id: SecureRandom.uuid,
          reason_type: "execution_capacity",
          subject_type: "agent",
          subject_id: agent.id,
          retry_at: 5.minutes.from_now.change(usec: 0),
          details: { "execution_request_id" => "browser-execution-wait" },
        ),
      )

      agent
    end

    def create_execution_denial!
      program = create_program!(name: "Browser denial")
      agent = track_record(materialize_agent_runtime!(program: program))
      deployment = create_deployment!(program: program)
      recognized_deployment = track_record(RecognizedDeployment.recognize!(agent: agent, deployment: deployment))
      conversation =
        track_record(
          create_conversation!(
            user: @tracked_users.first,
            agent: agent,
          ),
        )
      credential = create_provider_credential!(provider_key: "browser-provider-#{SecureRandom.hex(4)}")

      track_record(
        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: SecureRandom.uuid,
          state: "failed",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          agent: agent,
          recognized_deployment: recognized_deployment,
          recognized_deployment_key: recognized_deployment.recognized_deployment_key,
          contract_fingerprint: deployment.contract_fingerprint,
          deployment_fingerprint: deployment.deployment_fingerprint,
          deployment_activated_at: deployment.activated_at || Time.current.change(usec: 0),
          provider_credential: credential,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: agent.config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: {
            "provider_limiter" => provider_limiter_snapshot(
              provider_credential: credential,
              selected_model_ref: "openai/gpt-5.4",
            ),
            "execution_capacity" => RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent),
          },
          snapshot: {},
          error: { "message" => "execution_capacity_denied: queue full" },
        ),
      )

      agent
    end

    def create_deployment_with_backoff!
      program = create_program!(name: "Browser backoff")
      agent = track_record(materialize_agent_runtime!(program: program))
      deployment = create_deployment!(program: program)
      recognized_deployment = track_record(RecognizedDeployment.recognize!(agent: agent, deployment: deployment))

      track_record(
        RuntimeGovernance::RuntimeWaits.park!(
          owner_type: "RecognizedDeployment",
          owner_id: recognized_deployment.id,
          reason_type: "deployment_backoff",
          subject_type: "recognized_deployment",
          subject_id: recognized_deployment.id,
          retry_at: 10.minutes.from_now.change(usec: 0),
          details: { "attempt" => 2 },
        ),
      )
    end

    def create_provider_credential!(provider_key:)
      track_record(
        LLMProviderCredential.create!(
          provider_key: provider_key,
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        ),
      )
    end

    def create_program!(name:)
      track_record(
        create_agent_record!(
          name: "#{name} #{SecureRandom.hex(4)}",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        ),
      )
    end

    def create_deployment!(program:)
      track_record(
        create_runtime_binding_record!(
          agent_program: program,
          transport_kind: "websocket",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
          status: "active",
          health_status: "healthy",
          activated_at: Time.current.change(usec: 0),
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {},
          inspection_details: {},
        ),
      )
    end
end
