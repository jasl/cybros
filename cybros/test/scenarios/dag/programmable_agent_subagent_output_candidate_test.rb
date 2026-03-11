require "test_helper"

class DAG::ProgrammableAgentSubagentOutputCandidateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FinishingChildAgentExecutor
    def execute(node:, context:, stream:)
      _ = node
      _ = context
      _ = stream

      DAG::ExecutionResult.finished(content: "candidate from subagent")
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "subagent_wait returns a parent-owned output candidate without mutating the parent transcript" do
    parent = create_conversation!
    ctx = parent_context(parent)

    registry = DAG::ExecutorRegistry.new
    registry.register(
      Messages::AgentMessage.node_type_key,
      FinishingChildAgentExecutor.new,
    )

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      run_tool = Cybros::Subagent::Tools.build.find { |tool| tool.name == "subagent_run" }
      wait_tool = Cybros::Subagent::Tools.build.find { |tool| tool.name == "subagent_wait" }

      run = nil
      perform_enqueued_jobs do
        run =
          run_tool.call(
            {
              "name" => "candidate-worker",
              "prompt" => "Draft a user-facing answer",
              "agent_profile" => "subagent",
            },
            context: ctx,
          )
      end

      refute run.error?, run.text

      payload =
        JSON.parse(
          wait_tool.call(
            {
              "subagent_id" => JSON.parse(run.text).fetch("subagent_id"),
              "limit_turns" => 10,
              "timeout_ms" => 5,
            },
            context: ctx,
          ).text,
        )

      assert_equal(
        {
          "format" => "text",
          "content" => "candidate from subagent",
          "scope" => "full",
        },
        payload.fetch("assistant_output_candidate"),
      )
      assert_equal({ "final_output" => "candidate from subagent" }, payload.fetch("result"))

      transcript = parent.dag_graph.main_lane.transcript_recent_turns(limit_turns: 10, mode: :preview, include_deleted: false)
      assert_includes transcript.map { |node| node.fetch("node_type") }, "user_message"
      refute_includes transcript.to_json, "candidate from subagent"
    ensure
      DAG.executor_registry = original_registry
    end
  end

  private

    def parent_context(parent, agent_key: "main", agent_profile: "coding", context_turns: 50)
      graph = parent.dag_graph
      turn_id = ActiveRecord::Base.with_connection { |connection| connection.select_value("select uuidv7()") }
      from_node = nil

      graph.mutate!(turn_id: turn_id) do |m|
        from_node =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "parent",
            metadata: {},
          )
      end

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
            key: agent_key,
            agent_profile: agent_profile,
            context_turns: context_turns,
          },
        },
      )
    end
end
