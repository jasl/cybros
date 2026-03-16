require "test_helper"
require "tmpdir"
require_relative "../support/programmable_agent_runtime_test_support"

class BundledDefaultAgentExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "bundled claw conversations complete one Cybros-owned loop through planning finalization and before_finalize_output" do
    llm_server = MockLLMServer.new do |_payload|
      MockLLMServer.chat_response(content: "llm draft answer")
    end.start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      conversation = create_conversation!(title: "Bundled default")

      result = conversation.append_user_message!(content: "Inspect the repository status", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      draft = RunDraft.order(:created_at).last
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      assert_equal "claw", conversation.agent.bundled_agent_key
      assert_equal "finalized", draft.status
      assert_equal run.id, draft.materialized_conversation_run_id
      assert_equal run.id, draft.materialized_conversation_run_id
      assert_equal "bundled_claw.before_agent_step.v2", draft.planning.dig("step_plan", "kind")
      assert_equal "agent", run.runtime_governors.dig("execution_capacity", "scope_type")
      assert_equal conversation.agent_id, run.runtime_governors.dig("execution_capacity", "scope_id")

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

  test "bundled default bootstrap seeds the self-mutate skill into the live agent root" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        agent = Agents::BootstrapBundledDefaultService.ensure_agent!
        skill_path = agent.workspace_root_path.join("skills/self-mutate/SKILL.md")

        assert_predicate skill_path, :file?
        skill_text = skill_path.read
        assert_includes skill_text, "diff"
        assert_includes skill_text, "confirm"
        assert_includes skill_text, ".history"
        assert_includes skill_text, "next top-level turn"
        assert_includes skill_text, "../../SOUL.md"
        assert_includes skill_text, "../../USER.md"
        assert_includes skill_text, "../../skills/"
      end
    end
  end

  test "bundled default conversations expose split root conversation lane workspace semantics" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Workspace semantics", metadata: { "agent" => {} })

        payload = conversation.workspace_payload

        assert_equal conversation.agent.workspace_root_path.to_s, payload.fetch("root_path")
        assert_equal conversation.workspace_root_path.to_s, payload.fetch("conversation_path")
        assert_equal conversation.workspace_root_path.to_s, payload.fetch("cwd")
        assert_equal conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id).to_s, payload.fetch("lane_path")
        refute_equal payload.fetch("root_path"), payload.fetch("conversation_path")
        assert_equal File.join(payload.fetch("conversation_path"), ".lanes"), File.dirname(payload.fetch("lane_path"))
        assert_includes payload.fetch("lane_path"), "/.lanes/"
      end
    end
  end

  test "bundled default runtime can read protected root prompts from the conversation cwd" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Protected root read", metadata: { "agent" => {} })
        workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation).deep_stringify_keys
        deployment = conversation.agent.active_runtime_binding

        response =
          Agents::RPCClient.new(deployment: deployment).call(
            "tool.execute",
            {
              "implementation_ref" => "claw:read",
              "logical_tool_name" => "read",
              "arguments" => { "path" => "../../SOUL.md" },
              "execution_context" => { "workspace" => workspace },
              "session_context" => { "workspace" => workspace },
            },
          )

        result = AgentCore::Resources::Tools::ToolResult.from_h(response.fetch("result"))

        assert_equal conversation.agent.workspace_root_path.join("SOUL.md").read, result.text
        assert_predicate Pathname.new(workspace.fetch("conversation_path")), :directory?
        assert_predicate Pathname.new(workspace.fetch("lane_path")), :directory?
        assert_not result.error?
      end
    end
  end

  test "bundled default runtime rejects conversation-local shadows of reserved root files and skills" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      with_default_agent_workspace_root(workspace_root) do
        conversation = create_conversation!(title: "Reserved shadow paths", metadata: { "agent" => {} })
        workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation).deep_stringify_keys
        deployment = conversation.agent.active_runtime_binding
        invoke_tool =
          lambda do |logical_tool_name:, arguments:|
            Agents::RPCClient.new(deployment: deployment).call(
              "tool.execute",
              {
                "implementation_ref" => "claw:#{logical_tool_name}",
                "logical_tool_name" => logical_tool_name,
                "arguments" => arguments,
                "execution_context" => { "workspace" => workspace },
                "session_context" => { "workspace" => workspace },
              },
            )
          end

        read_result = AgentCore::Resources::Tools::ToolResult.from_h(invoke_tool.call(logical_tool_name: "read", arguments: { "path" => "SOUL.md" }).fetch("result"))
        write_result = AgentCore::Resources::Tools::ToolResult.from_h(invoke_tool.call(logical_tool_name: "write", arguments: { "path" => "SOUL.md", "content" => "shadow\n" }).fetch("result"))
        skill_result = AgentCore::Resources::Tools::ToolResult.from_h(invoke_tool.call(logical_tool_name: "write", arguments: { "path" => "skills/demo/SKILL.md", "content" => "shadow\n" }).fetch("result"))

        assert read_result.error?
        assert_includes read_result.text, "../../SOUL.md"
        assert write_result.error?
        assert_includes write_result.text, "../../SOUL.md"
        assert skill_result.error?
        assert_includes skill_result.text, "../../skills/demo/SKILL.md"
        refute_predicate conversation.workspace_root_path.join("SOUL.md"), :exist?
        refute_predicate conversation.workspace_root_path.join("skills/demo/SKILL.md"), :exist?
      end
    end
  end
end
