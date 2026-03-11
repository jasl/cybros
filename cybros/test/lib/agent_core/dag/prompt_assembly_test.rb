require "test_helper"

class AgentCore::DAG::PromptAssemblyTest < ActiveSupport::TestCase
  test "build renders lane prompt buffer sections into the system prompt" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = SecureRandom.uuid
    agent_node = nil

    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "summaries",
      seq: 10,
      kind: "summary",
      content: "Older work was summarized.",
      priority: 100,
      estimated_tokens: 26,
      metadata: { "source" => "compact_context" },
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "working_notes",
      seq: 10,
      kind: "note",
      content: "Remember to preserve the edge cases.",
      priority: 50,
      estimated_tokens: 34,
      metadata: {},
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "handoff",
      content: "Pending review: merge the lane state task.",
      priority: 25,
      estimated_tokens: 40,
      metadata: {},
    )

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Continue the refactor.",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
      )
    execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

    prompt =
      AgentCore::DAG::PromptAssembly.new(
        runtime: runtime,
        execution_context: execution_context,
      ).build(context_nodes: graph.context_for_full(agent_node.id))

    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="summaries">)
    assert_includes prompt.system_prompt, "Older work was summarized."
    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="working_notes">)
    assert_includes prompt.system_prompt, "Remember to preserve the edge cases."
    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="handoff">)
    assert_includes prompt.system_prompt, "Pending review: merge the lane state task."
  end
end
