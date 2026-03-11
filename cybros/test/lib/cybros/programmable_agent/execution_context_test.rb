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

    assert_equal(
      {
        "account_id" => Account.instance.id,
        "user_id" => conversation.user_id,
        "conversation_id" => conversation.id,
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

    subagent_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Subagent",
        agent_program: parent.agent_program,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        default_execution_target: parent.default_execution_target,
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "subagent" => {
            "subagent_id" => subagent_id,
            "parent_conversation_id" => parent.id.to_s,
            "parent_graph_id" => parent.dag_graph.id.to_s,
            "spawned_from_node_id" => parent_agent.id.to_s,
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
          "subagent_id" => subagent_id,
          "parent_turn_id" => parent_agent.turn_id,
          "parent_dag_node_id" => parent_agent.id,
        },
      },
      execution_context.to_h,
    )
  end
end
