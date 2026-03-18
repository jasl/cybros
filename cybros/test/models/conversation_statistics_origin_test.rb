require "test_helper"

class ConversationStatisticsOriginTest < ActiveSupport::TestCase
  test "normal runtime conversations default statistics sample_origin to runtime" do
    conversation = create_conversation!

    assert_equal "runtime", conversation.metadata.dig("statistics", "sample_origin")
    assert_equal "runtime", conversation.statistics_sample_origin
  end

  test "subagent backing conversations inherit runtime sample_origin by default" do
    parent = create_conversation!
    child = spawn_subagent_backing_conversation!(parent: parent)

    assert_equal "runtime", child.metadata.dig("statistics", "sample_origin")
    assert_equal "runtime", child.statistics_sample_origin
    assert_equal parent.id, SubagentThread.find(child.metadata.fetch("subagent_thread_id")).owner_conversation_id
  end

  test "subagent backing conversations inherit explicit non-runtime sample_origin" do
    parent =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding", "context_turns" => 50 },
          "statistics" => { "sample_origin" => "debug" },
        },
      )

    child = spawn_subagent_backing_conversation!(parent: parent)

    assert_equal "debug", child.metadata.dig("statistics", "sample_origin")
    assert_equal "debug", child.statistics_sample_origin
    assert_equal parent.dag_graph.id, SubagentThread.find(child.metadata.fetch("subagent_thread_id")).owner_graph_id
  end

  test "missing sample_origin normalizes to runtime during reads" do
    conversation = create_conversation!
    conversation.update_column("metadata", { "agent" => { "agent_profile" => "coding" } })

    assert_nil conversation.reload.metadata.dig("statistics", "sample_origin")
    assert_equal "runtime", conversation.statistics_sample_origin
  end

  private

    def spawn_subagent_backing_conversation!(parent:)
      tool = Cybros::Subagent::Tools.build.find { |entry| entry.name == "subagent_spawn" }
      graph = parent.dag_graph
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
      from_node = nil

      graph.mutate!(turn_id: turn_id) do |mutation|
        from_node =
          mutation.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "spawn",
            metadata: {},
          )
      end

      context =
        AgentCore::ExecutionContext.new(
          run_id: turn_id,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
          attributes: {
            dag: {
              graph_id: graph.id.to_s,
              node_id: from_node.id.to_s,
              lane_id: from_node.lane_id.to_s,
              turn_id: from_node.turn_id.to_s,
            },
            agent: {
              key: "main",
              agent_profile: parent.metadata.dig("agent", "agent_profile") || "coding",
              context_turns: parent.metadata.dig("agent", "context_turns") || 50,
            },
          },
        )

      result = tool.call({ "name" => "child", "prompt" => "child: hello" }, context: context)
      refute result.error?, result.text

      payload = JSON.parse(result.text)
      thread = SubagentThread.find(payload.fetch("subagent_id"))
      assert_equal parent.id, thread.owner_conversation_id
      assert_equal parent.dag_graph.id, thread.owner_graph_id
      assert_equal thread.child_graph_id, thread.child_conversation.dag_graph.id
      thread.child_conversation
    end
end
