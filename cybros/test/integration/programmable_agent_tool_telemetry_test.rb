require "test_helper"

class ProgrammableAgentToolTelemetryTest < ActiveSupport::TestCase
  setup do
    Statistics::ToolCallFact.delete_all
  end

  teardown do
    Statistics::ToolCallFact.delete_all
  end

  test "programmable tool facts retain routing dimensions and surface them in reliability stats" do
    conversation = create_conversation!
    graph = conversation.root_graph
    lane_id = graph.main_lane.id
    turn_id = uuidv7
    recognized_deployment = recognize_agent_runtime!(agent: conversation.agent)
    provider_credential = LLMProviderCredential.find_by!(provider_key: "dev")

    agent =
      create_agent_node!(
        graph: graph,
        lane_id: lane_id,
        turn_id: turn_id,
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
      )

    ConversationRun.create!(
      build_conversation_run_attributes(
        conversation: conversation,
        dag_node_id: agent.id,
        agent: conversation.agent,
        recognized_deployment: recognized_deployment,
        provider_credential: provider_credential,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: conversation.agent.config_schema_fingerprint,
        effective_policy: {},
        runtime_governors:
          runtime_governors_snapshot(
            provider_credential: provider_credential,
            selected_model_ref: "openai/gpt-5.4",
            agent: conversation.agent,
          ),
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
            "kernel_capability_registry_version" => "kernel:v1",
            "agent_capabilities_version" => "default-agent-capabilities:v1",
          },
        },
      ),
    )

    started_at = Time.current.change(usec: 0) - 2.seconds
    finished_at = started_at + 0.12.seconds

    task =
      create_connected_task!(
        graph: graph,
        from_node: agent,
        lane_id: lane_id,
        turn_id: turn_id,
        state: DAG::Node::FINISHED,
        name: "compact_context",
        requested_name: "compact_context",
        tool_call_id: "tc_programmable",
        source: "agent",
        started_at: started_at,
        finished_at: finished_at,
        metadata: {
          "tool" => {
            "logical_tool_name" => "compact_context",
            "effective_tool_id" => "etool_compact",
            "implementation_source" => "agent",
            "implementation_ref" => "agent://compact_context",
            "capability_registry_snapshot_id" => "cap_snapshot_123",
            "tool_surface_id" => "tool_surface_123",
          },
        },
        result: AgentCore::Resources::Tools::ToolResult.success(text: "ok"),
      )

    fact = Statistics::ToolCallFact.find_by!(task_node_id: task.id)
    stats = Cybros::Statistics::ToolReliabilityStats.snapshot

    assert_equal "compact_context", fact.logical_tool_name
    assert_equal "agent", fact.implementation_source
    assert_equal "agent://compact_context", fact.implementation_ref
    assert_equal "cap_snapshot_123", fact.capability_registry_snapshot_id
    assert_equal "kernel:v1", fact.kernel_capability_registry_version
    assert_equal "tool_surface_123", fact.tool_surface_id
    assert_equal "bundled_default.before_agent_step", fact.tool_surface_label
    assert_equal recognized_deployment.id, fact.recognized_deployment_id
    assert_equal recognized_deployment.recognized_deployment_key, fact.recognized_deployment_key
    assert_equal "default-agent-capabilities:v1", fact.agent_capabilities_version
    assert_equal 120, fact.duration_ms

    agent_row = stats.fetch("by_implementation_source").find { |row| row.fetch("implementation_source") == "agent" }
    tool_surface_row = stats.fetch("by_tool_surface_id").find { |row| row.fetch("tool_surface_id") == "tool_surface_123" }
    logical_tool_row = stats.fetch("by_logical_tool_name").find { |row| row.fetch("logical_tool_name") == "compact_context" }

    assert_equal 1, agent_row.fetch("total_calls")
    assert_equal 1, tool_surface_row.fetch("total_calls")
    assert_equal 1, logical_tool_row.fetch("total_calls")
  end

  private

    def create_agent_node!(graph:, lane_id:, turn_id:, provider_key:, model_ref:)
      graph.nodes.create!(
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        lane_id: lane_id,
        turn_id: turn_id,
        metadata: {},
        body_output: {
          "content" => "working",
          "provider_key" => provider_key,
          "model_ref" => model_ref,
        },
      )
    end

    def create_connected_task!(
      graph:,
      from_node:,
      lane_id:,
      turn_id:,
      state:,
      name:,
      requested_name: nil,
      tool_call_id: nil,
      source:,
      started_at: nil,
      finished_at: nil,
      metadata: {},
      result: nil
    )
      task = nil

      ApplicationRecord.transaction do
        task =
          graph.nodes.create!(
            node_type: Messages::Task.node_type_key,
            state: state,
            lane_id: lane_id,
            turn_id: turn_id,
            metadata: metadata,
            started_at: started_at,
            finished_at: finished_at,
            body_input: {
              "name" => name,
              "requested_name" => requested_name || name,
              "tool_call_id" => tool_call_id,
              "arguments" => {},
              "arguments_summary" => "{}",
              "name_resolution" => "exact",
              "arguments_resolution" => "original",
              "source" => source,
            },
            body_output: result ? { "result" => result.to_h } : {},
          )

        graph.edges.create!(
          graph_id: graph.id,
          from_node_id: from_node.id,
          to_node_id: task.id,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: {},
        )
      end

      task
    end

    def uuidv7
      ActiveRecord::Base.with_connection do |connection|
        connection.select_value("select uuidv7()")
      end
    end
end
