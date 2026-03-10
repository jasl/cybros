require "test_helper"

class BundledDefaultAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "bundled default conversations complete one Cybros-owned loop through planning finalization and compose" do
    conversation = create_conversation!(title: "Bundled default")

    result = conversation.append_user_message!(content: "Inspect the repository status")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

    assert_equal "default", conversation.agent_program.bundled_agent_key
    assert_equal "finalized", draft.status
    assert_equal run.id, draft.materialized_conversation_run_id
    assert_equal run.id, draft.materialized_conversation_run_id
    assert_equal "bundled_default.prepare.v1", draft.prepared_plan.fetch("kind")
    assert_equal conversation.default_execution_target_id, run.execution_target_id

    conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
    assert_includes claimed, agent_node.id

    DAG::Runner.run_node!(agent_node.id)

    agent = conversation.root_graph.nodes.find(agent_node.id)
    compose_invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "turn.compose")

    assert_equal DAG::Node::FINISHED, agent.reload.state
    assert_equal "succeeded", run.reload.state
    assert_equal "succeeded", compose_invocation.status
    assert_includes agent.body_output.fetch("content"), "Bundled default agent plan:"
    assert_includes agent.body_output.fetch("content"), "Inspect the repository status"
  end
end
