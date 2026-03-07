require "test_helper"

class ConversationSubagentActivityUiTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "assistant bubble renders a parent-visible subagent activity without mirroring child internal task names" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.root_graph

    turn = conversation.append_user_message!(content: "Delegate this", diagnostic_level: "debug")
    agent = turn.fetch(:agent_node)
    agent.mark_running!
    agent.body.merge_output!("content" => "Parent thinking")
    agent.body.save!

    child = create_child_conversation!(user: user, hidden_task_name: "child_internal_task")

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: agent.turn_id,
        metadata: {},
        body_input: {
          "name" => "subagent_run",
          "requested_name" => "subagent_run",
          "tool_call_id" => "tc_run",
          "arguments" => { "name" => "Research Agent" },
          "arguments_summary" => %({"name":"Research Agent"}),
        },
        body_output: {
          "result" => AgentCore::Resources::Tools::ToolResult.success(
            text:
              JSON.generate(
                {
                  "ok" => true,
                  "operation" => "run",
                  "child_conversation_id" => child.id.to_s,
                  "child_graph_id" => child.dag_graph.id.to_s,
                  "status" => "running",
                  "counts" => { "pending" => 0, "running" => 1, "awaiting_approval" => 0 },
                  "leaf" => {
                    "node_id" => child.dag_graph.leaf_nodes.where(lane_id: child.dag_graph.main_lane.id).order(:id).last.id.to_s,
                    "state" => "running",
                  },
                  "transcript_lines" => ["U:child: hello", "A:child: investigating"],
                  "diagnostic_level" => "debug",
                },
              ),
            metadata: {
              subagent: {
                "ok" => true,
                "operation" => "run",
                "child_conversation_id" => child.id.to_s,
                "child_graph_id" => child.dag_graph.id.to_s,
                "status" => "running",
                "counts" => { "pending" => 0, "running" => 1, "awaiting_approval" => 0 },
                "leaf" => {
                  "node_id" => child.dag_graph.leaf_nodes.where(lane_id: child.dag_graph.main_lane.id).order(:id).last.id.to_s,
                  "state" => "running",
                },
                "transcript_lines" => ["U:child: hello", "A:child: investigating"],
                "diagnostic_level" => "debug",
              },
            },
          ).to_h,
        },
      )

    stream = DAG::NodeEventStream.new(node: task)
    stream.activity_started!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
    )
    stream.activity_finished!(
      activity_id: "task:#{task.id}",
      activity_kind: "tool_call",
      phase: "execution",
      diagnostic_level: "debug",
    )

    get conversation_path(conversation)

    assert_response :success
    assert_select '[data-role="run-state-activity"][data-activity-kind="subagent"]', count: 1
    assert_select %(li[data-role="run-state-activity"][data-child-conversation-id="#{child.id}"]), count: 1
    assert_includes response.body, "Research Agent"
    assert_includes response.body, "Parent thinking"
    refute_includes response.body, "child_internal_task"
  end

  private

    def create_child_conversation!(user:, hidden_task_name:)
      child =
        Conversation.create!(
          user: user,
          title: "Child",
          metadata: {
            "agent" => {
              "key" => "subagent:child",
              "agent_profile" => "subagent",
              "context_turns" => 50,
            },
          },
        )

      graph = child.dag_graph
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

      graph.mutate!(turn_id: turn_id) do |m|
        user_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "child: hello",
            metadata: {},
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::RUNNING,
            metadata: { "turn_execution" => { "diagnostic_level" => "debug" } },
          )
        task =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::RUNNING,
            metadata: {},
            turn_id: turn_id,
            body_input: {
              "name" => hidden_task_name,
              "requested_name" => hidden_task_name,
              "tool_call_id" => "tc_hidden",
              "arguments" => {},
              "arguments_summary" => "{}",
            },
          )

        m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
        m.create_edge(from_node: user_node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
      end

      child
    end
end
