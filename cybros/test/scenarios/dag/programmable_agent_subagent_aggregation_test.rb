require "test_helper"

class DAG::ProgrammableAgentSubagentAggregationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class OrchestratingAgentExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      if subagent_conversation?(node.graph.attachable)
        return DAG::ExecutionResult.finished(content: "draft from #{node.graph.attachable.metadata.dig("subagent", "name")}")
      end

      case node.metadata["phase"].to_s
      when "plan_subagents"
        create_subagent_run_fanout!(node)
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 1 })
      when "collect_subagents"
        create_subagent_wait_fanout!(node)
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 1 })
      when "finalize_subagents"
        contents =
          node.graph.nodes.active
            .where(node_type: Messages::Task.node_type_key, turn_id: node.turn_id)
            .order(:id)
            .filter_map do |task|
              next unless task.body_input["name"] == "subagent_wait" && task.finished?

              AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result")).metadata.dig("subagent", "assistant_output_candidate", "content")
            end

        DAG::ExecutionResult.finished(
          content: "Aggregated: #{contents.join(" | ")}",
          usage: { "total_tokens" => 1 },
        )
      else
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 1 })
      end
    end

    private

      def subagent_conversation?(attachable)
        attachable.is_a?(Conversation) && attachable.metadata.dig("subagent", "subagent_id").present?
      end

      def create_subagent_run_fanout!(node)
        node.graph.mutate!(turn_id: node.turn_id) do |m|
          collector =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              metadata: { "phase" => "collect_subagents", "transcript_visible" => false },
            )

          %w[alpha beta].each do |name|
            task =
              m.create_node(
                node_type: Messages::Task.node_type_key,
                state: DAG::Node::PENDING,
                metadata: {},
                body_input: {
                  "name" => "subagent_run",
                  "requested_name" => "subagent_run",
                  "tool_call_id" => "tc_run_#{name}",
                  "arguments" => {
                    "name" => name,
                    "prompt" => "Draft a response for #{name}",
                    "agent_profile" => "subagent",
                  },
                  "arguments_summary" => %({"name":"#{name}","prompt":"Draft a response for #{name}","agent_profile":"subagent"}),
                },
              )

            m.create_edge(from_node: node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
            m.create_edge(from_node: task, to_node: collector, edge_type: DAG::Edge::DEPENDENCY)
          end
        end
      end

      def create_subagent_wait_fanout!(node)
        run_tasks =
          node.graph.nodes.active
            .where(node_type: Messages::Task.node_type_key, turn_id: node.turn_id)
            .order(:id)
            .select { |task| task.body_input["name"] == "subagent_run" && task.finished? }

        node.graph.mutate!(turn_id: node.turn_id) do |m|
          final =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              metadata: { "phase" => "finalize_subagents" },
            )

          run_tasks.each do |run_task|
            tool_result = AgentCore::Resources::Tools::ToolResult.from_h(run_task.body_output.fetch("result"))
            subagent_id = tool_result.metadata.dig("subagent", "subagent_id")
            task_name = run_task.body_input.dig("arguments", "name")

            task =
              m.create_node(
                node_type: Messages::Task.node_type_key,
                state: DAG::Node::PENDING,
                metadata: {},
                body_input: {
                  "name" => "subagent_wait",
                  "requested_name" => "subagent_wait",
                  "tool_call_id" => "tc_wait_#{task_name}",
                  "arguments" => {
                    "subagent_id" => subagent_id,
                    "timeout_ms" => 5,
                    "limit_turns" => 10,
                  },
                  "arguments_summary" => %({"subagent_id":"#{subagent_id}","timeout_ms":5,"limit_turns":10}),
                },
              )

            m.create_edge(from_node: node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
            m.create_edge(from_node: task, to_node: final, edge_type: DAG::Edge::DEPENDENCY)
          end
        end
      end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "final parent output is aggregated from subagent output candidates instead of direct child transcript writes" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    planner = create_root_planner!(graph)

    original_registry = DAG.executor_registry
    original_runtime_resolver = AgentCore::DAG.runtime_resolver

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::AgentMessage.node_type_key, OrchestratingAgentExecutor.new)
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
    AgentCore::DAG.runtime_resolver = runtime_resolver

    begin
      run_all_claimed_nodes!(graph)

      final = graph.nodes.where(node_type: Messages::AgentMessage.node_type_key, turn_id: planner.turn_id).order(:id).last
      assert_equal DAG::Node::FINISHED, final.state
      assert_equal "Aggregated: draft from alpha | draft from beta", final.body_output.fetch("content")

      transcript = graph.transcript_for(final.id)
      assert_equal [Messages::UserMessage.node_type_key, Messages::AgentMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }
      assert_equal "Aggregated: draft from alpha | draft from beta", transcript.last.dig("payload", "output_preview", "content")
      refute_includes transcript.to_json, "\"content\":\"draft from alpha\""
      refute_includes transcript.to_json, "\"content\":\"draft from beta\""

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  private

    def create_root_planner!(graph)
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
      planner = nil

      graph.mutate!(turn_id: turn_id) do |m|
        user =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "Coordinate two workers",
            metadata: {},
          )
        planner =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            metadata: { "phase" => "plan_subagents", "transcript_visible" => false },
          )
        m.create_edge(from_node: user, to_node: planner, edge_type: DAG::Edge::SEQUENCE)
      end

      planner
    end

    def runtime_resolver
      tools_registry = Cybros::AgentRuntimeResolver.build_tools_registry
      base_policy = AgentCore::Resources::Tools::Policy::AllowAll.new
      instrumenter = AgentCore::Observability::NullInstrumenter.new

      lambda do |node:|
        Cybros::AgentRuntimeResolver.runtime_for(
          node: node,
          base_tool_policy: base_policy,
          tools_registry: tools_registry,
          instrumenter: instrumenter,
        ).with(llm_options: { stream: false })
      end
    end

    def run_all_claimed_nodes!(graph)
      loop do
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 20, claimed_by: "test")
        break if claimed.empty?

        claimed.each do |node|
          perform_enqueued_jobs do
            DAG::Runner.run_node!(node.id)
          end
        end
      end
    end
end
