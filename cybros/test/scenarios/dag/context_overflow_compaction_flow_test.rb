require "test_helper"

class DAG::ContextOverflowCompactionFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "accumulated history overflow inserts a transient compact_context task without creating a durable summary node" do
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
    refute_nil agent_node

    compact_task =
      graph.nodes.active
        .where(turn_id: agent_node.turn_id, node_type: Messages::Task.node_type_key)
        .order(:id)
        .last

    assert_equal DAG::Node::FINISHED, compact_task.state
    assert_equal "compact_context", compact_task.body_input["name"]
    assert_equal "context_overflow", compact_task.metadata["generated_by"]
    assert compact_task.body_output["result"].present?

    refute graph.nodes.active.where(node_type: Messages::Summary.node_type_key).exists?
    assert oldest_user.reload.context_excluded?

    page_node_ids = conversation.message_page(limit: 50, mode: :full).fetch("messages").map { |message| message.fetch("node_id") }
    assert_includes page_node_ids, oldest_user.id
    assert_includes page_node_ids, user_node.id

    context_ids = conversation.context_for(agent_node.id, mode: :full).map { |node| node.fetch("node_id") }
    refute_includes context_ids, oldest_user.id
    assert_includes context_ids, compact_task.id
    assert_includes context_ids, user_node.id
    assert_includes context_ids, agent_node.id
  end

  private

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
end
