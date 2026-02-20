require "test_helper"

class DAG::SubgraphBranchAndMergeFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SubgraphAwareAgentExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      graph = node.graph

      graph.mutate!(turn_id: node.turn_id) do |m|
        task = m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          idempotency_key: "tool",
          body_input: { "name" => "tool" },
          body_output: { "result" => "ok" },
          metadata: {}
        )

        m.create_edge(from_node: task, to_node: node, edge_type: DAG::Edge::SEQUENCE, metadata: { "generated_by" => "executor" })
      end

      DAG::ExecutionResult.finished(
        payload: { "content" => "done" },
        usage: { "total_tokens" => 1 }
      )
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "product flow: fork, merge, continue branch, archive, and merge archived branch again" do
    conversation = Conversation.create!(title: "Demo")
    graph = conversation.dag_graph

    main_topic = conversation.ensure_main_topic
    main_subgraph = main_topic.dag_subgraph
    assert main_subgraph.present?
    assert_equal DAG::Subgraph::MAIN, main_subgraph.role

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::AgentMessage.node_type_key, SubgraphAwareAgentExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      main_user = nil
      turn_id = "0194f3c0-0000-7000-8000-00000000e001"

      graph.mutate!(turn_id: turn_id) do |m|
        main_user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hello", metadata: {})
      end

      main_agent = graph.nodes.active.find_by!(turn_id: turn_id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING)
      assert_equal main_subgraph.id, main_user.subgraph_id
      assert_equal main_subgraph.id, main_agent.subgraph_id

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [main_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(main_agent.id)
      assert_equal DAG::Node::FINISHED, main_agent.reload.state

      task = graph.nodes.active.find_by!(turn_id: main_agent.turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool")
      assert_equal main_subgraph.id, task.subgraph_id

      branch_topic = conversation.fork_topic_from(from_node: main_agent, title: "Branch", user_content: "What if?")
      branch_subgraph = branch_topic.dag_subgraph
      assert branch_subgraph.present?
      assert_equal DAG::Subgraph::BRANCH, branch_subgraph.role
      assert_equal main_subgraph.id, branch_subgraph.parent_subgraph_id
      assert_equal main_agent.id, branch_subgraph.forked_from_node_id

      branch_root = graph.nodes.active.find(branch_subgraph.root_node_id)
      assert_equal branch_subgraph.id, branch_root.subgraph_id

      branch_agent =
        graph.nodes.active.find_by!(
          subgraph_id: branch_subgraph.id,
          turn_id: branch_root.turn_id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING
        )

      context_ids = graph.context_for(branch_agent.id).map { |n| n.fetch("node_id") }
      assert_includes context_ids, main_user.id
      assert_includes context_ids, main_agent.id
      assert_includes context_ids, branch_root.id
      assert_includes context_ids, branch_agent.id

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [branch_agent.id], claimed.map(&:id)
      DAG::Runner.run_node!(branch_agent.id)
      assert_equal DAG::Node::FINISHED, branch_agent.reload.state

      task = graph.nodes.active.find_by!(turn_id: branch_agent.turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool")
      assert_equal branch_subgraph.id, task.subgraph_id

      main_user_2 = nil
      graph.mutate! do |m|
        main_user_2 = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Main followup", metadata: {})
        m.create_edge(from_node: main_agent, to_node: main_user_2, edge_type: DAG::Edge::SEQUENCE)
      end

      main_agent_2 =
        graph.nodes.active.find_by!(
          subgraph_id: main_subgraph.id,
          turn_id: main_user_2.turn_id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING
        )

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [main_agent_2.id], claimed.map(&:id)
      DAG::Runner.run_node!(main_agent_2.id)
      assert_equal DAG::Node::FINISHED, main_agent_2.reload.state

      branch_user_2 = nil
      graph.mutate! do |m|
        branch_user_2 =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "Branch followup",
            subgraph_id: branch_subgraph.id,
            metadata: {}
          )
        m.create_edge(from_node: branch_agent, to_node: branch_user_2, edge_type: DAG::Edge::SEQUENCE)
      end

      branch_agent_2 =
        graph.nodes.active.find_by!(
          subgraph_id: branch_subgraph.id,
          turn_id: branch_user_2.turn_id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING
        )

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [branch_agent_2.id], claimed.map(&:id)
      DAG::Runner.run_node!(branch_agent_2.id)
      assert_equal DAG::Node::FINISHED, branch_agent_2.reload.state

      merge_node = conversation.merge_topic_into_main(source_topic: branch_topic, metadata: { "reason" => "test" })
      assert_equal main_subgraph.id, merge_node.subgraph_id
      assert_equal DAG::Node::PENDING, merge_node.state

      branch_subgraph.reload
      assert branch_subgraph.archived_at.blank?

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [merge_node.id], claimed.map(&:id)
      DAG::Runner.run_node!(merge_node.id)
      assert_equal DAG::Node::FINISHED, merge_node.reload.state

      merge_context_ids = graph.context_for(merge_node.id).map { |n| n.fetch("node_id") }
      [main_user.id, main_agent.id, branch_root.id, branch_agent.id, merge_node.id].each do |node_id|
        assert_includes merge_context_ids, node_id
      end

      branch_user_3 = nil
      graph.mutate! do |m|
        branch_user_3 =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "Branch after merge",
            subgraph_id: branch_subgraph.id,
            metadata: {}
          )
        m.create_edge(from_node: branch_agent_2, to_node: branch_user_3, edge_type: DAG::Edge::SEQUENCE)
      end

      branch_agent_3 =
        graph.nodes.active.find_by!(
          subgraph_id: branch_subgraph.id,
          turn_id: branch_user_3.turn_id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING
        )

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [branch_agent_3.id], claimed.map(&:id)
      DAG::Runner.run_node!(branch_agent_3.id)
      assert_equal DAG::Node::FINISHED, branch_agent_3.reload.state

      branch_user_4 = nil
      graph.mutate! do |m|
        branch_user_4 =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            content: "Branch in-flight before archive",
            subgraph_id: branch_subgraph.id,
            metadata: {}
          )
        m.create_edge(from_node: branch_agent_3, to_node: branch_user_4, edge_type: DAG::Edge::SEQUENCE)
      end

      branch_agent_4 =
        graph.nodes.active.find_by!(
          subgraph_id: branch_subgraph.id,
          turn_id: branch_user_4.turn_id,
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING
        )

      graph.mutate! do |m|
        m.archive_subgraph!(subgraph: branch_subgraph, mode: :finish, reason: "archive_branch")
      end
      assert branch_subgraph.reload.archived_at.present?

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [branch_agent_4.id], claimed.map(&:id)
      DAG::Runner.run_node!(branch_agent_4.id)
      assert_equal DAG::Node::FINISHED, branch_agent_4.reload.state

      task = graph.nodes.active.find_by!(turn_id: branch_agent_4.turn_id, node_type: Messages::Task.node_type_key, idempotency_key: "tool")
      assert_equal branch_subgraph.id, task.subgraph_id

      error =
        assert_raises(ActiveRecord::RecordInvalid) do
          graph.nodes.create!(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            subgraph_id: branch_subgraph.id,
            body_input: { "content" => "Branch new turn after archive" },
            metadata: {}
          )
        end
      assert_match(/Subgraph is archived/, error.message)

      merge_node_2 = conversation.merge_topic_into_main(source_topic: branch_topic, metadata: { "reason" => "merge_again" })
      assert_equal main_subgraph.id, merge_node_2.subgraph_id
      assert_equal DAG::Node::PENDING, merge_node_2.state

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [merge_node_2.id], claimed.map(&:id)
      DAG::Runner.run_node!(merge_node_2.id)
      assert_equal DAG::Node::FINISHED, merge_node_2.reload.state

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
