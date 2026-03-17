require "test_helper"

class RuntimeGovernanceObservabilityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "build groups current waits and recent runtime outcomes by governed subject" do
    travel_to(Time.zone.parse("2026-03-09 12:00:00 UTC")) do
      reset_runtime_governance_state!
      provider_credential = create_provider_credential!(provider_key: "openai-observability")
      create_provider_pressure!(provider_credential: provider_credential)

      blocked_execution = create_blocked_execution_subject!
      recovered_execution = create_recovered_execution_subject!
      recognized_deployment = create_deployment_backoff_subject!

      feed = RuntimeGovernance::ObservabilityFeed.call(recent_limit: 10)

      assert_equal 1, feed.fetch("parked_wait_counts").fetch("provider_limit")
      assert_equal 1, feed.fetch("parked_wait_counts").fetch("execution_capacity")
      assert_equal 1, feed.fetch("parked_wait_counts").fetch("deployment_backoff")

      provider_group =
        feed.fetch("subjects").find do |group|
          group.fetch("subject_type") == "llm_provider_credential" &&
            group.fetch("subject_id") == provider_credential.id
        end
      refute_nil provider_group
      assert_equal "Provider credential", provider_group.fetch("subject_kind")
      assert_includes provider_group.fetch("parked_waits").map { |wait| wait.fetch("reason_type") }, "provider_limit"
      assert_includes provider_group.fetch("recent_events").map { |event| event.fetch("kind") }, "reservation_released"
      assert_includes provider_group.fetch("recent_events").filter_map { |event| event["provider_request_id"] }, "provider-req-1"

      blocked_group =
        feed.fetch("subjects").find do |group|
          group.fetch("subject_type") == "agent" &&
            group.fetch("subject_id") == blocked_execution.fetch(:subject_id)
        end
      refute_nil blocked_group
      assert_equal "Agent", blocked_group.fetch("subject_kind")
      assert_includes blocked_group.fetch("parked_waits").map { |wait| wait.fetch("owner_id") }, blocked_execution.fetch(:parked_run).id

      recovered_group =
        feed.fetch("subjects").find do |group|
          group.fetch("subject_type") == "agent" &&
            group.fetch("subject_id") == recovered_execution.fetch(:agent).id
        end
      refute_nil recovered_group
      recent_kinds = recovered_group.fetch("recent_events").map { |event| event.fetch("kind") }
      assert_includes recent_kinds, "wait_resumed"
      assert_includes recent_kinds, "lease_released"
      assert_includes recent_kinds, "execution_capacity_denied"
      denial_message = recovered_group.fetch("recent_events").find { |event| event.fetch("kind") == "execution_capacity_denied" }.fetch("summary")
      assert_match(/execution_capacity_denied/, denial_message)

      deployment_group =
        feed.fetch("subjects").find do |group|
          group.fetch("subject_type") == "recognized_deployment" &&
            group.fetch("subject_id") == recognized_deployment.id
        end
      refute_nil deployment_group
      assert_includes deployment_group.fetch("parked_waits").map { |wait| wait.fetch("reason_type") }, "deployment_backoff"
    end
  end

  test "build excludes stale rows from recent recovery and activity buckets" do
    travel_to(Time.zone.parse("2026-03-09 12:00:00 UTC")) do
      reset_runtime_governance_state!
      provider_credential = create_provider_credential!(provider_key: "openai-stale")
      create_provider_activity_record!(
        provider_credential: provider_credential,
        provider_request_id: "stale-provider-req",
        status: "released",
        at: 3.days.ago,
      )

      stale_agent = create_governed_agent!(name: "Stale agent", max_concurrent_tasks: 1, max_queued_tasks: 1)
      stale_execution = create_queued_execution!(agent: stale_agent)
      stale_run = stale_execution.fetch(:run)
      create_execution_wait_record!(
        owner_id: stale_run.id,
        subject_type: "agent",
        subject_id: stale_agent.id,
        status: "resumed",
        at: 3.days.ago,
      )
      create_execution_lease_record!(
        holder_id: stale_run.id,
        subject_type: "agent",
        subject_id: stale_agent.id,
        status: "released",
        at: 3.days.ago,
      )
      create_execution_denial_record!(agent: stale_agent, at: 3.days.ago)

      feed = RuntimeGovernance::ObservabilityFeed.build(recent_limit: 10)

      refute feed.fetch(:subject_groups).any? { |group| group.fetch(:subject_id) == provider_credential.id }
      refute feed.fetch(:subject_groups).any? { |group| group.fetch(:subject_id) == stale_agent.id }
    end
  end

  test "build preserves recent activity coverage across multiple governed subjects" do
    travel_to(Time.zone.parse("2026-03-09 12:00:00 UTC")) do
      reset_runtime_governance_state!
      first_credential = create_provider_credential!(provider_key: "provider-a")
      second_credential = create_provider_credential!(provider_key: "provider-b")

      create_provider_activity_record!(
        provider_credential: first_credential,
        provider_request_id: "provider-a-req",
        status: "released",
        at: 2.minutes.ago,
      )
      create_provider_activity_record!(
        provider_credential: second_credential,
        provider_request_id: "provider-b-req",
        status: "released",
        at: 1.minute.ago,
      )

      feed = RuntimeGovernance::ObservabilityFeed.build(recent_limit: 1)

      first_group =
        feed.fetch(:subject_groups).find do |group|
          group.fetch(:subject_type) == "llm_provider_credential" &&
            group.fetch(:subject_id) == first_credential.id
        end
      second_group =
        feed.fetch(:subject_groups).find do |group|
          group.fetch(:subject_type) == "llm_provider_credential" &&
            group.fetch(:subject_id) == second_credential.id
        end

      refute_nil first_group
      refute_nil second_group
      assert_equal ["provider-a-req"], first_group.fetch(:recent_provider_activity).map { |event| event.fetch(:request_id) }
      assert_equal ["provider-b-req"], second_group.fetch(:recent_provider_activity).map { |event| event.fetch(:request_id) }
    end
  end

  private

    def reset_runtime_governance_state!
      RunDraft.delete_all
      ConversationRun.delete_all
      RuntimeWait.delete_all
      ExecutionCapacityLease.delete_all
      ProviderBudgetReservation.delete_all
    end

    def create_provider_pressure!(provider_credential:)
      RuntimeGovernance::ProviderBudgetReservations.acquire!(
        provider_credential: provider_credential,
        provider_request_id: "provider-req-1",
        request_units: 1,
        estimated_tokens: 80,
        owner_type: "RunDraft",
        owner_id: "draft-provider-1",
        now: Time.current,
      )

      blocked =
        RuntimeGovernance::ProviderBudgetReservations.acquire!(
          provider_credential: provider_credential,
          provider_request_id: "provider-req-2",
          request_units: 1,
          estimated_tokens: 80,
          owner_type: "RunDraft",
          owner_id: "draft-provider-2",
          now: Time.current + 1.second,
        )

      RuntimeGovernance::ProviderBudgetReservations.release!(
        provider_credential: provider_credential,
        provider_request_id: "provider-req-1",
        now: Time.current + 2.seconds,
      )

      blocked.fetch(:runtime_wait)
    end

    def create_provider_activity_record!(provider_credential:, provider_request_id:, status:, at:)
      ProviderBudgetReservation.create!(
        provider_credential: provider_credential,
        provider_request_id: provider_request_id,
        request_units: 1,
        estimated_tokens: 50,
        actual_tokens: 40,
        reserved_until: at,
        status: status,
        reconciliation_metadata: {},
        created_at: at,
        updated_at: at,
      )
    end

    def create_blocked_execution_subject!
      agent = create_governed_agent!(name: "Blocked agent", max_concurrent_tasks: 1, max_queued_tasks: 2)
      first = create_queued_execution!(agent: agent)
      second = create_queued_execution!(agent: agent)

      DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
      DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

      {
        agent: agent,
        subject_id: agent.id,
        parked_run: second.fetch(:run).reload,
      }
    end

    def create_recovered_execution_subject!
      agent = create_governed_agent!(name: "Recovered agent", max_concurrent_tasks: 1, max_queued_tasks: 1)
      first = create_queued_execution!(agent: agent)
      second = create_queued_execution!(agent: agent)
      third = create_queued_execution!(agent: agent)

      DAG::Scheduler.claim_executable_nodes(graph: first.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
      DAG::Scheduler.claim_executable_nodes(graph: second.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")
      DAG::Scheduler.claim_executable_nodes(graph: third.fetch(:conversation).dag_graph, limit: 10, claimed_by: "test")

      RuntimeGovernance::ExecutionCapacityEnforcer.release!(conversation_run: first.fetch(:run))

      {
        agent: agent,
        parked_run: second.fetch(:run).reload,
        denied_run: third.fetch(:run).reload,
      }
    end

    def create_deployment_backoff_subject!
      agent = create_governed_agent!(name: "Backoff agent")
      runtime_binding = create_runtime_binding!(agent: agent)
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: runtime_binding)

      RuntimeGovernance::RuntimeWaits.park!(
        owner_type: "RecognizedDeployment",
        owner_id: recognized_deployment.id,
        reason_type: "deployment_backoff",
        subject_type: "recognized_deployment",
        subject_id: recognized_deployment.id,
        retry_at: 5.minutes.from_now.change(usec: 0),
        details: { "attempt" => 2 },
        now: Time.current + 3.seconds,
      )

      recognized_deployment
    end

    def create_execution_wait_record!(owner_id:, subject_type:, subject_id:, status:, at:)
      RuntimeWait.create!(
        owner_type: "ConversationRun",
        owner_id: owner_id,
        reason_type: "execution_capacity",
        subject_type: subject_type,
        subject_id: subject_id,
        retry_at: at,
        ordering_key: "#{at.utc.iso8601(6)}:#{SecureRandom.uuid}",
        details: { "execution_request_id" => "conversation_run:#{owner_id}" },
        status: status,
        created_at: at,
        updated_at: at,
      )
    end

    def create_execution_lease_record!(holder_id:, subject_type:, subject_id:, status:, at:)
      ExecutionCapacityLease.create!(
        subject_type: subject_type,
        subject_id: subject_id,
        execution_request_id: "conversation_run:#{holder_id}",
        holder_type: "ConversationRun",
        holder_id: holder_id,
        slots: 1,
        lease_expires_at: at,
        heartbeat_at: at,
        status: status,
        recovery_metadata: {},
        created_at: at,
        updated_at: at,
      )
    end

    def create_execution_denial_record!(agent:, at:)
      denied_execution = create_queued_execution!(agent: agent)
      denied_run = denied_execution.fetch(:run)
      denied_run.update!(
        state: "failed",
        error: { "message" => "execution_capacity_denied: stale failure" },
        finished_at: at,
        updated_at: at,
      )
      denied_run
    end

    def create_provider_credential!(provider_key:)
      LLMProviderCredential.create!(
        provider_key: provider_key,
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 1,
        requests_per_minute: 10,
        tokens_per_minute: 1_000,
        burst_limit: 4,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
      )
    end

    def create_queued_execution!(agent: nil, max_concurrent_tasks: 1, max_queued_tasks: 2)
      agent ||= create_governed_agent!(max_concurrent_tasks: max_concurrent_tasks, max_queued_tasks: max_queued_tasks)
      if agent.status == "active" && agent.health_status == "healthy"
        runtime_binding = agent
      else
        runtime_binding = create_runtime_binding!(agent: agent)
      end
      recognized_deployment = RecognizedDeployment.recognize!(agent: agent, deployment: runtime_binding)
      conversation = create_conversation!(agent: agent)
      graph = conversation.dag_graph
      user = graph.nodes.create!(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, metadata: {})
      node = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      graph.edges.create!(from_node_id: user.id, to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)

      credential = create_provider_credential!(provider_key: "provider-#{SecureRandom.hex(4)}")

      run =
        ConversationRun.create!(
          conversation: conversation,
          dag_node_id: node.id,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          snapshot_version: 1,
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          agent: agent,
          recognized_deployment: recognized_deployment,
          recognized_deployment_key: recognized_deployment.recognized_deployment_key,
          contract_fingerprint: agent.published_contract_fingerprint,
          deployment_fingerprint: runtime_binding.deployment_fingerprint,
          deployment_activated_at: runtime_binding.activated_at || Time.current.change(usec: 0),
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
        )

      { conversation: conversation, node: node, run: run, agent: agent }
    end

    def create_governed_agent!(name: "Fixture Agent", max_concurrent_tasks: 4, max_queued_tasks: 16)
      create_agent_record!(
        name: "#{name} #{SecureRandom.hex(4)}",
        config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
      )
    end

    def create_runtime_binding!(agent:)
      create_runtime_binding_record!(
        agent: agent,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: agent.published_contract_fingerprint,
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
      )
    end
end
