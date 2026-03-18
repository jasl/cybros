require "test_helper"
require "tmpdir"

class Cybros::LaneProcesses::ToolsTest < ActiveSupport::TestCase
  def start_tool
    @start_tool ||= Cybros::LaneProcesses::Tools.build.find { |tool| tool.name == "start_background_process" }
  end

  def list_tool
    @list_tool ||= Cybros::LaneProcesses::Tools.build.find { |tool| tool.name == "list_lane_processes" }
  end

  def read_log_tool
    @read_log_tool ||= Cybros::LaneProcesses::Tools.build.find { |tool| tool.name == "read_lane_process_log" }
  end

  def stop_tool
    @stop_tool ||= Cybros::LaneProcesses::Tools.build.find { |tool| tool.name == "stop_lane_process" }
  end

  test "build exposes lane background process tools" do
    names = Cybros::LaneProcesses::Tools.build.map(&:name).sort

    assert_equal %w[
      list_lane_processes
      read_lane_process_log
      start_background_process
      stop_lane_process
    ], names
  end

  test "start list read and stop manage a real background process" do
    Dir.mktmpdir("lane-process-tools-test") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!
        task_node = create_lane_process_task_node!(conversation: conversation)
        context = execution_context_for(node: task_node)

        start_result =
          start_tool.call(
            {
              "command" => "printf 'ready\\n'; sleep 30",
              "title" => "Preview server",
              "port_hints" => [3000],
            },
            context: context,
          )

        refute start_result.error?, start_result.text
        payload = JSON.parse(start_result.text)
        lane_process = LaneProcess.find(payload.fetch("id"))

        assert_equal "running", payload.fetch("status")
        assert_equal "Preview server", payload.fetch("title")
        assert_equal [3000], payload.fetch("port_hints")
        assert_predicate lane_process, :running?
        assert lane_process.pid.present?
        assert lane_process.log_path.present?
        assert File.file?(lane_process.log_path)

        list_result = list_tool.call({}, context: context)
        refute list_result.error?, list_result.text
        list_payload = JSON.parse(list_result.text)
        assert_equal [lane_process.id], list_payload.fetch("items").map { |item| item.fetch("id") }

        log_lines = []
        10.times do
          read_result = read_log_tool.call({ "lane_process_id" => lane_process.id, "tail_lines" => 20 }, context: context)
          refute read_result.error?, read_result.text
          log_lines = JSON.parse(read_result.text).fetch("lines")
          break if log_lines.any? { |line| line.include?("ready") }

          sleep 0.1
        end
        assert log_lines.any? { |line| line.include?("ready") }

        stop_result = stop_tool.call({ "lane_process_id" => lane_process.id }, context: context)
        refute stop_result.error?, stop_result.text
        assert_equal "killed", JSON.parse(stop_result.text).fetch("status")
        assert_equal "killed", lane_process.reload.status
        assert lane_process.ended_at.present?
      end
    end
  end

  test "agent tools expose other-lane processes as summaries but only manage the current lane" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: conversation.chat_lane.id, metadata: {})
    branch_process =
      LaneProcess.create!(
        conversation: conversation,
        lane: branch_lane,
        status: LaneProcess::RUNNING,
        started_by_type: LaneProcess::AGENT,
        title: "Branch preview",
        command: "bin/dev",
        started_at: Time.current,
      )

    task_node = create_lane_process_task_node!(conversation: conversation, lane: conversation.chat_lane)
    context = execution_context_for(node: task_node)

    list_result = list_tool.call({}, context: context)
    refute list_result.error?, list_result.text
    list_payload = JSON.parse(list_result.text)
    item = list_payload.fetch("items").find { |entry| entry.fetch("id") == branch_process.id }

    assert_equal false, item.fetch("manageable")
    refute item.key?("log_path")

    read_result = read_log_tool.call({ "lane_process_id" => branch_process.id }, context: context)
    assert read_result.error?
    assert_includes read_result.text, "current lane cannot manage this background process"

    stop_result = stop_tool.call({ "lane_process_id" => branch_process.id }, context: context)
    assert stop_result.error?
    assert_includes stop_result.text, "current lane cannot manage this background process"
  end

  private

    def create_lane_process_task_node!(conversation:, lane: conversation.chat_lane)
      graph = conversation.dag_graph
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
      task_node = nil

      graph.mutate!(turn_id: turn_id) do |mutation|
        user_node =
          mutation.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "start service",
            metadata: {},
          )
        task_node =
          mutation.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::PENDING,
            content: "",
            metadata: {},
            lane: lane,
          )
        mutation.create_edge(from_node: user_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
      end

      task_node
    end

    def execution_context_for(node:)
      AgentCore::ExecutionContext.new(
        run_id: node.turn_id,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
        attributes: {
          dag: {
            graph_id: node.graph_id.to_s,
            node_id: node.id.to_s,
            lane_id: node.lane_id.to_s,
            turn_id: node.turn_id.to_s,
          },
          agent: {
            key: "main",
            agent_profile: "coding",
            context_turns: 50,
          },
        },
      )
    end
end
