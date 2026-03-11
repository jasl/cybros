require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class BundledDefaultAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "bundled default conversations complete one Cybros-owned loop through planning finalization and before_finalize_output" do
    llm_server = MockLLMServer.new do |_payload|
      MockLLMServer.chat_response(content: "llm draft answer")
    end.start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      conversation = create_conversation!(title: "Bundled default")

      result = conversation.append_user_message!(content: "Inspect the repository status", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      draft = RunDraft.order(:created_at).last
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      assert_equal "default", conversation.agent_program.bundled_agent_key
      assert_equal "finalized", draft.status
      assert_equal run.id, draft.materialized_conversation_run_id
      assert_equal run.id, draft.materialized_conversation_run_id
      assert_equal "bundled_default.before_agent_step.v2", draft.planning.dig("step_plan", "kind")
      assert_equal conversation.default_execution_target_id, run.execution_target_id

      conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      agent = conversation.root_graph.nodes.find(agent_node.id)
      finalize_invocation = AgentRPCInvocation.find_by!(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")

      assert_equal DAG::Node::FINISHED, agent.reload.state
      assert run.reload.succeeded?,
        "run_state=#{run.reload.state} run_error=#{run.reload.error.inspect} invocations=#{AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id).order(:created_at).pluck(:method, :status, :error_snapshot).inspect}"
      assert_equal "succeeded", finalize_invocation.status, finalize_invocation.error_snapshot.inspect
      assert_equal "llm draft answer", agent.body_output.fetch("content")
      assert_equal ["before_finalize_output"], AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id).order(:created_at).pluck(:method)
    end
  ensure
    llm_server&.shutdown
  end
end
