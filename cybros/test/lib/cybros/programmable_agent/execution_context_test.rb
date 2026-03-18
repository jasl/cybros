require "test_helper"

class Cybros::ProgrammableAgent::ExecutionContextTest < ActiveSupport::TestCase
  test "builds typed session and execution contexts from conversation and node records" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    session_context = Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation)
    execution_context =
      Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
        conversation: conversation,
        node: agent_node,
      )
    session_workspace = conversation.workspace_payload
    execution_workspace = conversation.workspace_payload(lane_id: agent_node.lane_id)

    assert_equal(
      {
        "account_id" => Account.instance.id,
        "user_id" => conversation.user_id,
        "conversation_id" => conversation.id,
        "workspace" => session_workspace,
      },
      session_context.to_h,
    )

    assert_equal(
      {
        "account_id" => Account.instance.id,
        "user_id" => conversation.user_id,
        "conversation_id" => conversation.id,
        "graph_id" => conversation.dag_graph.id,
        "lane_id" => agent_node.lane_id,
        "turn_id" => agent_node.turn_id,
        "dag_node_id" => agent_node.id,
        "execution_scope" => "primary",
        "workspace" => execution_workspace,
      },
      execution_context.to_h,
    )
  end

  test "marks subagent execution context with explicit scope and subagent identity" do
    parent = create_conversation!(title: "Parent")
    parent_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    parent_agent = nil

    parent.dag_graph.mutate!(turn_id: parent_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Delegate this",
          metadata: {},
        )

      parent_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: parent_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Subagent",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: {
          "agent" => { "agent_profile" => "coding" },
        },
      )

    child_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    child_agent = nil

    child.dag_graph.mutate!(turn_id: child_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Do the delegated work",
          metadata: {},
        )

      child_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: child_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    thread =
      SubagentThread.create!(
        id: ActiveRecord::Base.connection.select_value("select uuidv7()"),
        owner_conversation: parent,
        owner_graph: parent.dag_graph,
        owner_turn: DAG::Turn.find(parent_agent.turn_id),
        owner_node: parent_agent,
        child_conversation: child,
        child_graph: child.dag_graph,
        requested_name: "child",
        title: "Subagent",
        agent_profile: "subagent",
        context_turns: 50,
        diagnostic_level: "standard",
        status: "active",
        child_status: "pending",
        depth: 1,
        last_snapshot: {},
        final_snapshot: {},
      )

    child.update!(
      metadata: child.metadata.merge(
        "subagent_thread_id" => thread.id,
        "owner_conversation_id" => parent.id,
        "owner_graph_id" => parent.dag_graph.id,
        "owner_turn_id" => parent_agent.turn_id,
        "owner_node_id" => parent_agent.id,
        "depth" => 1,
      ),
    )

    execution_context =
      Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
        conversation: child,
        node: child_agent,
      )
    execution_workspace = child.workspace_payload(lane_id: child_agent.lane_id)

    assert_equal(
      {
        "account_id" => Account.instance.id,
        "user_id" => child.user_id,
        "conversation_id" => child.id,
        "graph_id" => child.dag_graph.id,
        "lane_id" => child_agent.lane_id,
        "turn_id" => child_agent.turn_id,
        "dag_node_id" => child_agent.id,
        "execution_scope" => "subagent",
        "subagent" => {
          "subagent_id" => thread.id,
          "parent_turn_id" => parent_agent.turn_id,
          "parent_dag_node_id" => parent_agent.id,
          "depth" => 1,
        },
        "workspace" => execution_workspace,
      },
      execution_context.to_h,
    )
  end

  test "does not infer subagent execution scope from metadata alone" do
    parent = create_conversation!(title: "Parent")
    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Dangling subagent",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "subagent" => {
            "subagent_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
            "parent_turn_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
            "parent_dag_node_id" => ActiveRecord::Base.connection.select_value("select uuidv7()"),
            "depth" => 9,
          },
        },
      )

    child_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    child_agent = nil

    child.dag_graph.mutate!(turn_id: child_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Do the delegated work",
          metadata: {},
        )

      child_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: child_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    execution_context =
      Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
        conversation: child,
        node: child_agent,
      )

    assert_equal "primary", execution_context.to_h.fetch("execution_scope")
    refute execution_context.to_h.key?("subagent")
  end
end
