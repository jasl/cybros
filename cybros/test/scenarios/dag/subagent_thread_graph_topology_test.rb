require "test_helper"

class DAG::SubagentThreadGraphTopologyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "subagent run creates a separate child graph whose owner is traceable through subagent_threads" do
    parent = create_conversation!(title: "Parent")
    graph = parent.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    from_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      from_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "delegate",
          metadata: {},
        )
    end

    ctx =
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
            agent_profile: "coding",
            context_turns: 50,
          },
        },
      )

    run_tool = Cybros::Subagent::Tools.build.find { |tool| tool.name == "subagent_run" }
    result =
      run_tool.call(
        {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
        },
        context: ctx,
      )

    refute result.error?, result.text

    subagent_id = JSON.parse(result.text).fetch("subagent_id")
    thread = SubagentThread.find(subagent_id)

    refute_equal thread.owner_graph_id, thread.child_graph_id
    assert_equal parent.id, thread.owner_conversation_id
    assert_equal graph.id, thread.owner_graph_id
    assert_equal from_node.turn_id, thread.owner_turn_id
    assert_equal from_node.id, thread.owner_node_id
    assert_equal thread.child_conversation.dag_graph.id, thread.child_graph_id
    assert_equal [], DAG::GraphAudit.scan(graph: graph)
    assert_equal [], DAG::GraphAudit.scan(graph: thread.child_graph)
  end

  test "abnormal child termination creates a parent-local notice without merging the child graph back into the parent" do
    parent = create_conversation!(title: "Parent")
    graph = parent.dag_graph
    owner_turn = parent.append_user_message!(content: "Delegate this")
    owner_node = owner_turn.fetch(:agent_node)
    owner_node.mark_running!

    thread =
      SubagentThreads::ControlPlane.spawn!(
        parent: parent,
        owner_graph: graph,
        owner_turn: DAG::Turn.find(owner_node.turn_id),
        owner_node: owner_node,
        request: {
          "name" => "child",
          "prompt" => "child: hello",
          "agent_profile" => "subagent",
          "context_turns" => 50,
          "title" => "Research Agent",
          "diagnostic_level" => "debug",
        },
      )
    child_agent = thread.child_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).sole
    child_agent.mark_running!
    child_agent.mark_errored!(error: "boom")

    SubagentThreads::LifecycleSync.sync_from_node!(node: child_agent.reload)

    notice =
      graph.nodes.active
        .where(turn_id: owner_node.turn_id, node_type: Messages::Task.node_type_key)
        .order(:id)
        .to_a
        .find { |node| node.body_input["name"] == "subagent_notice" }

    refute_nil notice
    assert_equal graph.id, notice.graph_id
    assert_equal thread.child_graph_id, thread.child_conversation.dag_graph.id
    refute_equal graph.id, thread.child_graph_id
    assert_equal [], DAG::GraphAudit.scan(graph: graph)
    assert_equal [], DAG::GraphAudit.scan(graph: thread.child_graph)
  end
end
