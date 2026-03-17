require "test_helper"

class DAG::UserInputWhileRunningFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FixedReplyExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      reply = node.metadata["reply"].to_s
      DAG::ExecutionResult.finished(payload: { "content" => reply }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-openai")
  end

  test "user input while agent running: queue policy keeps the current turn running and schedules the next turn afterward" do
    conversation =
      create_conversation!(
        metadata: {
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph
    lane = graph.main_lane

    first = conversation.append_user_message!(content: "u1")
    user_1 = first.fetch(:user_node)
    agent_1 = first.fetch(:agent_node)
    agent_1.update!(metadata: agent_1.metadata.merge("reply" => "a1"))

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent_1.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent_1.reload.state

    second = conversation.append_user_message!(content: "u2")
    user_2 = second.fetch(:user_node)
    agent_2 = second.fetch(:agent_node)
    agent_2.update!(metadata: agent_2.metadata.merge("reply" => "a2"))

    assert graph.edges.active.exists?(from_node_id: agent_1.id, to_node_id: user_2.id, edge_type: DAG::Edge::SEQUENCE)
    assert graph.edges.active.exists?(
      from_node_id: agent_1.id,
      to_node_id: agent_2.id,
      edge_type: DAG::Edge::DEPENDENCY,
      metadata: { "generated_by" => "queue_policy" }
    )

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [], claimed.map(&:id), "agent_2 must not be claimable while agent_1 is running"

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedReplyExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      DAG::Runner.run_node!(agent_1.id)
      assert_equal DAG::Node::FINISHED, agent_1.reload.state

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_equal %w[u1 a1 u2 a2], contents

      context = lane.context_for(agent_2.id)
      assert_equal [user_1.id, agent_1.id, user_2.id, agent_2.id], context.map { |n| n.fetch("node_id") }

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "user input while agent running: interrupt_new_turn stops the interrupted closure and starts a fresh turn from the last stable parent" do
    conversation =
      create_conversation!(
        metadata: {
          "input_policy" => {
            "running_input_policy" => "interrupt_new_turn",
            "interrupted_output_policy" => "keep_context",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph
    lane = graph.main_lane

    first = conversation.append_user_message!(content: "u1")
    user_1 = first.fetch(:user_node)
    agent_1 = first.fetch(:agent_node)
    agent_1.update!(metadata: agent_1.metadata.merge("reply" => "a1"))

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent_1.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent_1.reload.state

    stale_turn = "0194f3c0-0000-7000-8000-00000000e202"
    stale_user = nil
    stale_agent = nil

    graph.mutate!(turn_id: stale_turn) do |m|
      stale_user =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f203",
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "stale",
          metadata: { "fragments" => ["stale"] }
        )
      stale_agent =
        m.create_node(
          id: "0194f3c0-0000-7000-8000-00000000f204",
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: { "reply" => "stale" }
        )

      m.create_edge(from_node: agent_1, to_node: stale_user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: stale_user, to_node: stale_agent, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(
        from_node: agent_1,
        to_node: stale_agent,
        edge_type: DAG::Edge::DEPENDENCY,
        metadata: { "generated_by" => "queue_policy" }
      )
    end

    stale_run =
      create_conversation_run!(conversation: conversation, dag_node_id: stale_agent.id)

    second = conversation.append_user_message!(content: "u2")
    user_2 = second.fetch(:user_node)
    agent_2 = second.fetch(:agent_node)
    agent_2.update!(metadata: agent_2.metadata.merge("reply" => "a2"))

    assert_equal DAG::Node::STOPPED, agent_1.reload.state
    assert_equal DAG::Node::STOPPED, stale_agent.reload.state
    assert_equal "canceled", stale_run.reload.state

    sequence_parent_id =
      graph.edges.active.where(to_node_id: user_2.id, edge_type: DAG::Edge::SEQUENCE).order(:id).pick(:from_node_id)
    assert_equal user_1.id, sequence_parent_id
    refute graph.edges.active.exists?(from_node_id: agent_1.id, to_node_id: user_2.id, edge_type: DAG::Edge::SEQUENCE)
    refute graph.edges.active.exists?(to_node_id: agent_2.id, edge_type: DAG::Edge::DEPENDENCY)

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedReplyExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_includes contents, "u1"
      assert_includes contents, "Stopped: interrupt_new_turn"
      assert_equal ["u2", "a2"], contents.last(2)

      context = lane.context_for(agent_2.id)
      context_ids = context.map { |n| n.fetch("node_id") }
      assert_includes context_ids, user_1.id
      assert_includes context_ids, agent_1.id
      assert_includes context_ids, stale_agent.id
      assert_includes context_ids, user_2.id
      assert_includes context_ids, agent_2.id

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "user input while agent running: interrupt_new_turn with discard_context keeps interrupted output visible but removes it from future context" do
    conversation =
      create_conversation!(
        metadata: {
          "input_policy" => {
            "running_input_policy" => "interrupt_new_turn",
            "interrupted_output_policy" => "discard_context",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )
    graph = conversation.dag_graph
    lane = graph.main_lane

    first = conversation.append_user_message!(content: "u1")
    user_1 = first.fetch(:user_node)
    agent_1 = first.fetch(:agent_node)
    agent_1.update!(metadata: agent_1.metadata.merge("reply" => "a1"))

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent_1.id], claimed.map(&:id)
    assert_equal DAG::Node::RUNNING, agent_1.reload.state

    second = conversation.append_user_message!(content: "u2")
    user_2 = second.fetch(:user_node)
    agent_2 = second.fetch(:agent_node)
    agent_2.update!(metadata: agent_2.metadata.merge("reply" => "a2"))

    assert_equal DAG::Node::STOPPED, agent_1.reload.state
    assert agent_1.context_excluded?

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, FixedReplyExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_2.id], claimed.map(&:id)

      DAG::Runner.run_node!(agent_2.id)
      assert_equal DAG::Node::FINISHED, agent_2.reload.state

      transcript_page = lane.transcript_page(limit_turns: 10)
      contents =
        transcript_page.fetch("transcript").map do |node|
          node.dig("payload", "input", "content").to_s.presence ||
            node.dig("payload", "output_preview", "content").to_s
        end
      assert_includes contents, "u1"
      assert_includes contents, "Stopped: interrupt_new_turn"
      assert_equal ["u2", "a2"], contents.last(2)

      context = lane.context_for(agent_2.id)
      context_ids = context.map { |n| n.fetch("node_id") }
      assert_includes context_ids, user_1.id
      refute_includes context_ids, agent_1.id
      assert_equal [user_1.id, user_2.id, agent_2.id], context_ids

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  private

    def create_conversation_run!(conversation:, dag_node_id:)
      program = create_program!
      deployment = create_deployment!(program)
      agent = create_agent_runtime!(agent: program, execution_profile: build_default_execution_profile!, deployment: deployment)
      recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)

      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: conversation,
          dag_node_id: dag_node_id,
          agent: agent,
          recognized_deployment: recognized_deployment,
          effective_permission_mode: conversation.permission_mode,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: program.config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors_snapshot(selected_model_ref: "openai/gpt-5.4", agent: agent),
          snapshot: { "origin" => "dag_user_input_flow_test" },
          error: {},
        ).merge(debug: {}),
      )
    end

    def create_program!
      create_agent_record!(
        name: "User Input Flow Program #{SecureRandom.hex(4)}",
        config_namespace: "dag.user_input.fixture.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
      )
    end

    def create_deployment!(program)
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
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
      )
    end
end
