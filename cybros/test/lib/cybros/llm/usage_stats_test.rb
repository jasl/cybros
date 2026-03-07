require "test_helper"

class Cybros::LLM::UsageStatsTest < ActiveSupport::TestCase
  def create_finished_agent_node!(conversation:, provider_key:, model_ref:, input_tokens:, output_tokens:, finished_at: Time.current)
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    node = nil
    graph.mutate!(turn_id: turn_id) do |m|
      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {
            "usage" => {
              "input_tokens" => input_tokens,
              "output_tokens" => output_tokens,
              "cache_creation_tokens" => 0,
              "cache_read_tokens" => 0,
            },
          },
        )
    end

    node.update!(finished_at: finished_at)
    node.body.update!(
      output: {
        "provider_key" => provider_key,
        "model_ref" => model_ref,
        "api_model" => model_ref.split("/", 2).last,
      },
    )

    node
  end

  test "aggregates per-user by model_ref and global by provider_key" do
    u1 = create_user!(role: :owner, email: "u1@example.com")
    u2 = create_user!(role: :owner, email: "u2@example.com")

    c1 = Conversation.create!(user: u1, title: "C1", metadata: { "agent" => { "agent_profile" => "coding" } })
    c2 = Conversation.create!(user: u2, title: "C2", metadata: { "agent" => { "agent_profile" => "coding" } })

    create_finished_agent_node!(conversation: c1, provider_key: "openai", model_ref: "openai/gpt-5.4", input_tokens: 3, output_tokens: 7)
    create_finished_agent_node!(conversation: c1, provider_key: "openai", model_ref: "openai/gpt-5.4", input_tokens: 2, output_tokens: 1)
    create_finished_agent_node!(conversation: c2, provider_key: "openrouter", model_ref: "openrouter/openai-gpt-5.4", input_tokens: 10, output_tokens: 5)

    u1_stats = Cybros::LLM::UsageStats.for_user(user: u1)
    assert_equal 2, u1_stats.dig("totals", "calls")
    assert_equal 5, u1_stats.dig("totals", "input_tokens")
    assert_equal 8, u1_stats.dig("totals", "output_tokens")

    by_model = u1_stats.fetch("by_model_ref")
    assert_equal 1, by_model.length
    assert_equal "openai/gpt-5.4", by_model.first.fetch("model_ref")
    assert_equal 13, by_model.first.fetch("total_tokens")

    global = Cybros::LLM::UsageStats.global_by_provider_key
    keys = global.map { |r| r.fetch("provider_key") }
    assert_includes keys, "openai"
    assert_includes keys, "openrouter"

    openrouter = global.find { |row| row.fetch("provider_key") == "openrouter" }
    assert_equal 15, openrouter.fetch("total_tokens")
  end
end
