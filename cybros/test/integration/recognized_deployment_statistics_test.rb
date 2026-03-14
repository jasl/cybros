require "test_helper"

class RecognizedDeploymentStatisticsTest < ActiveSupport::TestCase
  test "runtime reliability keeps recognized deployment key slices after the dimension row is deleted" do
    conversation = create_conversation!
    recognized_deployment = recognize_agent_runtime!(agent: conversation.agent)
    graph = conversation.root_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    agent =
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: turn_id,
        metadata: {},
        body_output: {
          "content" => "working",
          "provider_key" => "openai",
          "model_ref" => "openai/gpt-5.4",
        },
      )

    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: agent.id,
        agent: conversation.agent,
        recognized_deployment: recognized_deployment,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
        effective_policy: {},
        runtime_governors: runtime_governors_snapshot(selected_model_ref: "openai/gpt-5.4", agent: conversation.agent),
        snapshot: {
          "draft" => {
            "planning" => {
              "tool_surface" => {
                "tool_surface_label" => "bundled_default.before_agent_step",
              },
            },
          },
          "capability_snapshot" => {
            "capability_registry_snapshot_id" => "cap_snapshot_123",
          },
        },
      ),
    )

    task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: conversation.chat_lane.id,
        turn_id: turn_id,
        metadata: {},
        body_input: {
          "name" => "shell_exec",
          "requested_name" => "shell_exec",
          "tool_call_id" => "tc_runtime",
          "arguments" => { "command" => "pwd" },
          "arguments_summary" => "{\"command\":\"pwd\"}",
          "name_resolution" => "exact",
          "arguments_resolution" => "original",
          "source" => "shell",
        },
        body_output: {
          "result" => AgentCore::Resources::Tools::ToolResult.success(text: "ok").to_h,
        },
      )
    graph.edges.create!(
      graph_id: graph.id,
      from_node_id: agent.id,
      to_node_id: task.id,
      edge_type: DAG::Edge::SEQUENCE,
      metadata: {},
    )

    fact = Statistics::ToolCallFact.find_by!(task_node_id: task.id)
    stats = Cybros::Statistics::ToolReliabilityStats.snapshot(scope: Statistics::ToolCallFact.where(task_node_id: task.id))

    assert_equal recognized_deployment.id, fact.recognized_deployment_id
    assert_equal recognized_deployment.recognized_deployment_key, fact.recognized_deployment_key
    assert_equal 1,
      stats.fetch("by_recognized_deployment_key")
        .find { |row| row.fetch("recognized_deployment_key") == recognized_deployment.recognized_deployment_key }
        .fetch("total_calls")

    AgentRPCInvocation.where(recognized_deployment_id: recognized_deployment.id).update_all(last_session_id: nil)
    AgentRPCSession.where(recognized_deployment_id: recognized_deployment.id).update_all(agent_rpc_invocation_id: nil)
    AgentRPCInvocation.where(recognized_deployment_id: recognized_deployment.id).delete_all
    AgentRPCSession.where(recognized_deployment_id: recognized_deployment.id).delete_all
    recognized_deployment.destroy!

    fact.reload
    stats_after =
      Cybros::Statistics::ToolReliabilityStats.snapshot(scope: Statistics::ToolCallFact.where(task_node_id: task.id))

    assert_nil fact.recognized_deployment_id
    assert_equal recognized_deployment.recognized_deployment_key, fact.recognized_deployment_key
    assert_equal 1,
      stats_after.fetch("by_recognized_deployment_key")
        .find { |row| row.fetch("recognized_deployment_key") == recognized_deployment.recognized_deployment_key }
        .fetch("total_calls")
  end
end
