require "test_helper"
require "fileutils"

class ForkedAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "forked custom agents complete one Cybros-owned loop through planning finalization and compose" do
    root = Dir.mktmpdir("cybros-agent-workspace-")
    runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
    runtime_setting.assign_attributes(
      default_worker_concurrency: 12,
      queue_overrides: {},
      alert_thresholds: {},
      agent_workspace_root: root,
    )
    runtime_setting.save!

    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    forked = AgentPrograms::ForkService.call!(source_program: bundled, name: "Forked assistant")
    conversation = create_conversation!(title: "Forked")
    conversation.update!(
      agent_program: forked,
      agent_config_schema_fingerprint: forked.config_schema_fingerprint,
    )

    result = conversation.append_user_message!(content: "Review the current worktree")
    agent_node = result.fetch(:agent_node)
    draft = RunDraft.order(:created_at).last
    run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

    conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
    claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
    assert_includes claimed, agent_node.id

    DAG::Runner.run_node!(agent_node.id)

    agent = conversation.root_graph.nodes.find(agent_node.id)

    assert_equal "custom", forked.source_kind
    assert_equal bundled.id, forked.forked_from_agent_program_id
    assert_equal "finalized", draft.status
    assert_equal run.id, draft.materialized_conversation_run_id
    assert_equal forked.id, run.agent_program_id
    assert_equal DAG::Node::FINISHED, agent.reload.state
    assert_equal "succeeded", run.reload.state
    assert_includes agent.body_output.fetch("content"), "Review the current worktree"
  ensure
    FileUtils.rm_rf(root) if root.present?
  end
end
