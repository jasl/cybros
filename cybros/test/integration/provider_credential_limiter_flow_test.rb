require "test_helper"
require "simple_inference"

class ProviderCredentialLimiterFlowTest < ActiveSupport::TestCase
  class StubAdapter < SimpleInference::HTTPAdapter
    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    attr_reader :calls

    def call(request)
      @calls << request
      @handler.call(request)
    end
  end

  test "runner parks the node durably when provider admission is blocked" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000f400"
    credential = create_provider_credential!(max_concurrent_requests: 1)

    user = nil
    agent = nil
    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    RuntimeGovernance::ProviderBudgetReservations.acquire!(
      provider_credential: credential,
      provider_request_id: "already-active",
      request_units: 1,
      estimated_tokens: 10,
      owner_type: "RunDraft",
      owner_id: "draft-existing",
    )

    adapter =
      StubAdapter.new do |_req|
        raise "remote provider should not be called while blocked"
      end
    provider = build_provider(adapter: adapter)
    instrumenter = AgentCore::Observability::TraceRecorder.new(capture: :safe)
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: provider,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: instrumenter,
        execution_context_attributes: {
          runtime_governance: {
            provider_credential_id: credential.id,
            provider_key: credential.provider_key,
          },
        },
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, AgentCore::DAG::Executors::AgentMessageExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent.id)

      agent.reload
      assert_equal DAG::Node::PENDING, agent.state
      assert agent.claim_after_at.present?
      assert_operator agent.claim_after_at, :>, Time.current
      assert_nil agent.claimed_at
      assert_nil agent.claimed_by
      assert_nil agent.lease_expires_at
      assert_equal "provider_limit", agent.metadata.dig("runtime_wait", "reason_type")
      assert_equal 1, RuntimeWait.where(reason_type: "provider_limit", owner_type: "DAG::Node", owner_id: agent.id).count
      assert_equal 0, adapter.calls.length
      assert_includes instrumenter.events.map { |event| event[:name] }, "agent_core.runtime_wait"
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  private

  def build_provider(adapter:)
    client = SimpleInference::Client.new(base_url: "http://example.com", api_key: "x", adapter: adapter)
    AgentCore::Resources::Provider::SimpleInferenceProvider.new(client: client)
  end

  def create_provider_credential!(attributes = {})
    provider_key = attributes[:provider_key] || "openai-#{SecureRandom.hex(4)}"
    LLMProviderCredential.create!(
      {
        provider_key: provider_key,
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 1,
        requests_per_minute: 60,
        tokens_per_minute: 120_000,
        burst_limit: 8,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
      }.merge(attributes),
    )
  end
end
