require "test_helper"

class DAG::ContextOverflowCompactionFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RoleAwareTokenCounter < AgentCore::Resources::TokenCounter::Base
    def count_text(text)
      text.to_s.length
    end

    def count_messages(messages, per_message_overhead: 0)
      _ = per_message_overhead

      Array(messages).sum do |message|
        next 0 if message.respond_to?(:system?) && message.system?

        message.respond_to?(:text) ? message.text.to_s.length : 0
      end
    end

    def count_tools(tools)
      _ = tools
      0
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "accumulated history overflow no longer inserts compact_context before the next agent step" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "oversize" => {
              "single_message" => {
                "soft_threshold_ratio" => 0.9,
                "hard_threshold_ratio" => 0.95,
              },
              "multi_message" => {
                "strategy" => "compact_context",
              },
            },
          },
        },
      )
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    token_counter = token_counter_for(conversation)
    budget = effective_prompt_budget_tokens_for(conversation)
    chunk = content_for_minimum_tokens(token_counter: token_counter, minimum_tokens: (budget / 3.0).ceil)

    sequence_parent = nil
    oldest_user = nil

    3.times do |index|
      created =
        create_finished_turn!(
          graph: graph,
          lane: lane,
          user_content: "history-#{index}\n#{chunk}",
          agent_content: "reply-#{index}\n#{chunk}",
          sequence_parent: sequence_parent,
        )
      oldest_user ||= created.fetch(:user_node)
      sequence_parent = created.fetch(:agent_node)
    end

    projected_tokens = projected_context_tokens_with_new_message(conversation: conversation, content: "follow up")
    assert_operator projected_tokens, :>, budget

    result = nil

    assert_difference -> { ConversationRun.count }, +1 do
      result = conversation.append_user_message!(content: "follow up")
    end

    user_node = result.fetch(:user_node)
    agent_node = result.fetch(:agent_node)
    assert_nil result[:compact_task]
    refute_nil agent_node

    refute graph.nodes.active.where(turn_id: agent_node.turn_id, node_type: Messages::Task.node_type_key).exists?

    refute graph.nodes.active.where(node_type: Messages::Summary.node_type_key).exists?
    refute oldest_user.reload.context_excluded?

    page_node_ids = conversation.message_page(limit: 50, mode: :full).fetch("messages").map { |message| message.fetch("node_id") }
    assert_includes page_node_ids, oldest_user.id
    assert_includes page_node_ids, user_node.id

    context_ids = conversation.context_for(agent_node.id, mode: :full).map { |node| node.fetch("node_id") }
    assert_includes context_ids, oldest_user.id
    assert_includes context_ids, user_node.id
    assert_includes context_ids, agent_node.id
  end

  test "single-message oversize still uses compress_input without adding compact_context" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "oversize" => {
              "single_message" => {
                "soft_threshold_ratio" => 0.1,
                "hard_threshold_ratio" => 0.9,
                "soft_strategy" => "compress_input",
                "hard_strategy" => "product_guard",
              },
              "multi_message" => {
                "strategy" => "compact_context",
              },
            },
          },
        },
      )

    content =
      content_for_minimum_tokens(
        token_counter: token_counter_for(conversation),
        minimum_tokens: (effective_prompt_budget_tokens_for(conversation) / 3.0).ceil,
      )

    result = conversation.append_user_message!(content: content)

    guard_node = result.fetch(:guard_node)
    agent_node = result.fetch(:agent_node)

    assert_equal "compress_input", guard_node.body_input["name"]
    assert_nil result[:compact_task]
    refute graph_tasks_for(conversation: conversation, turn_id: agent_node.turn_id).any? { |task| task.body_input["name"] == "compact_context" }
  end

  test "noop compact_context result suppresses same-fingerprint near-hard-cap enqueue" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000d210"

    agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Need room #{"x" * 90}",
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

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: NullProvider.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: { stream: false },
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        context_window_tokens: 100,
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
        token_counter: RoleAwareTokenCounter.new,
      )

    initial_budget = build_budget_for(agent: agent, runtime: runtime)
    assert_equal "near_hard_cap", initial_budget.metadata.dig("context_budget", "budget_state")
    assert_equal "enqueue_compact", initial_budget.metadata.dig("context_budget", "budget_action")

    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: conversation.chat_lane.id,
      turn_id: agent.turn_id,
      metadata: {
        "source" => "context_budget_policy",
        "context_budget" => {
          "budget_fingerprint" => initial_budget.metadata.dig("context_budget", "budget_fingerprint"),
        },
      },
      body_input: {
        "name" => "compact_context",
        "requested_name" => "compact_context",
        "source" => "context_budget_policy",
        "arguments" => {},
        "arguments_summary" => "{}",
      },
      body_output: {
        "result" => AgentCore::Resources::Tools::ToolResult.success(text: "noop", metadata: { "noop" => true }).to_h,
      },
    )

    suppressed_budget = build_budget_for(agent: agent, runtime: runtime)

    assert_equal initial_budget.metadata.dig("context_budget", "budget_fingerprint"), suppressed_budget.metadata.dig("context_budget", "budget_fingerprint")
    assert_equal "near_hard_cap", suppressed_budget.metadata.dig("context_budget", "budget_state")
    assert_equal "none", suppressed_budget.metadata.dig("context_budget", "budget_action")
  end

  private

    class NullProvider < AgentCore::Resources::Provider::Base
      def name = "null_provider"

      def chat(**)
        raise "null provider should not be called"
      end
    end

    def create_finished_turn!(graph:, lane:, user_content:, agent_content:, sequence_parent:)
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      created = nil

      graph.mutate!(turn_id: turn_id) do |m|
        user_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: lane.id,
            content: user_content,
            metadata: { "fragments" => [user_content] },
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: lane.id,
            body_output: { "content" => agent_content },
            metadata: {},
          )

        m.create_edge(from_node: sequence_parent, to_node: user_node, edge_type: DAG::Edge::SEQUENCE) if sequence_parent
        m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

        created = { user_node: user_node, agent_node: agent_node }
      end

      created
    end

    def content_for_minimum_tokens(token_counter:, minimum_tokens:)
      content = +"history context detail "

      while token_counter.count_text(content) < minimum_tokens
        content << content
      end

      content
    end

    def projected_context_tokens_with_new_message(conversation:, content:)
      context_nodes =
        conversation.chat_lane.transcript_recent_turns(limit_turns: 1000, mode: :full) + [synthetic_user_node(conversation: conversation, content: content)]
      adapted = AgentCore::DAG::ContextAdapter.new(context_nodes: context_nodes).call
      token_counter = token_counter_for(conversation)

      token_counter.count_text(adapted.system_prompt.to_s) + token_counter.count_messages(adapted.messages)
    end

    def synthetic_user_node(conversation:, content:)
      {
        "node_id" => "synthetic-user",
        "turn_id" => "synthetic-turn",
        "lane_id" => conversation.chat_lane.id,
        "node_type" => Messages::UserMessage.node_type_key,
        "state" => DAG::Node::FINISHED,
        "payload" => {
          "input" => { "content" => content },
          "output" => {},
          "output_preview" => {},
        },
        "metadata" => {},
      }
    end

    def token_counter_for(conversation)
      resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation)
      model_spec = Cybros::LLM::Catalog.effective.model(resolution.fetch(:provider_key), resolution.fetch(:model_key))

      AgentCore::Resources::TokenCounter::Estimator.new(
        token_estimator: Cybros::TokenEstimation.estimator(tokenizer_root_path: Cybros::TokenEstimation.tokenizer_root, strict: false),
        model_hint: model_spec.fetch("tokenizer_hint", model_spec.fetch("api_model")).to_s,
      )
    end

    def effective_prompt_budget_tokens_for(conversation)
      resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: conversation)
      model_spec = Cybros::LLM::Catalog.effective.model(resolution.fetch(:provider_key), resolution.fetch(:model_key))
      model_spec.fetch("context_window_tokens").to_i
    end

    def graph_tasks_for(conversation:, turn_id:)
      conversation.dag_graph.nodes.active.where(turn_id: turn_id, node_type: Messages::Task.node_type_key).to_a
    end

    def build_budget_for(agent:, runtime:)
      execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent, runtime: runtime)
      AgentCore::DAG::ContextBudgetManager.new(
        node: agent,
        runtime: runtime,
        execution_context: execution_context,
      ).build_prompt(context_nodes: agent.graph.context_for_full(agent.id))
    end
end
