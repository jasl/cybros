require "test_helper"
require "fileutils"
require "json"
require Agents::BundledSources.path_for("claw").join("test/support/callback_harness")

class DAG::AgentToolCallsFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class PlanningAndFinalAgentExecutor
    def execute(node:, context:, stream:)
      _ = stream
      phase = node.metadata["phase"].to_s

      if phase == "plan"
        create_tool_calls_and_join_message(node)
        DAG::ExecutionResult.finished(payload: {}, usage: { "total_tokens" => 2 })
      else
        task_names = context.filter_map { |n| n.dig("payload", "input", "name") }.map(&:to_s).reject(&:blank?).sort
        task_previews = context.filter_map { |n| n.dig("payload", "output_preview", "result") }.map(&:to_s).reject(&:blank?)

        content = +"Final answer"
        content << " (tasks=#{task_names.join(",")})" if task_names.any?
        content << "\n" << task_previews.join("\n") if task_previews.any?

        DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 3 })
      end
    end

    private

    def create_tool_calls_and_join_message(node)
      graph = node.graph

      graph.mutate!(turn_id: node.turn_id) do |m|
        hash_task = m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "hash_task",
          body_input: { "name" => "hash_task" },
          metadata: {}
        )
        array_task = m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "array_task",
          body_input: { "name" => "array_task" },
          metadata: {}
        )
        final = m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          idempotency_key: "final_answer",
          metadata: { "phase" => "final" }
        )

        m.create_edge(from_node: node, to_node: hash_task, edge_type: DAG::Edge::SEQUENCE)
        m.create_edge(from_node: node, to_node: array_task, edge_type: DAG::Edge::SEQUENCE)

        m.create_edge(from_node: hash_task, to_node: final, edge_type: DAG::Edge::DEPENDENCY)
        m.create_edge(from_node: array_task, to_node: final, edge_type: DAG::Edge::DEPENDENCY)
      end
    end
  end

  class ToolCallExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      name = node.body_input["name"].to_s

      result =
        case name
        when "hash_task"
          { "a" => 1, "b" => 2 }
        when "array_task"
          [1, 2, 3]
        else
          name
        end

      DAG::ExecutionResult.finished(payload: { "result" => result }, usage: { "total_tokens" => 1 })
    end
  end

  class BundledClawToolProvider
    def initialize(workspace_root:, agent_root: nil, lane_root: nil, callback_session: nil)
      @workspace_root = workspace_root
      @agent_root = agent_root || workspace_root
      @lane_root = lane_root
      @callback_session = callback_session
      @application =
        Cybros::Agents::Claw::Application.new(
          source_root: Agents::BundledSources.path_for("claw"),
          deployment_fingerprint: "deployment:test-claw",
          required_bearer: "secret://agent",
        )
    end

    attr_reader :workspace_root, :agent_root, :lane_root

    def name = "programmable_agent"

    def execute_programmable_tool!(**payload)
      logical_tool_name = payload[:logical_tool_name].to_s.presence || payload["logical_tool_name"].to_s
      @application.call(
        method_name: "tool.execute",
        params: payload.deep_stringify_keys.merge(
          "session_context" => { "workspace" => workspace_payload },
          "execution_context" => { "workspace" => workspace_payload },
        ).tap do |params|
          if @callback_session.present? && logical_tool_name.start_with?("memory_")
            params["callback_session"] = @callback_session
          end
        end,
      )
    end

    private

      def workspace_payload
        {
          "conversation_id" => "conversation:test",
          "root_path" => agent_root.to_s,
          "conversation_path" => workspace_root.to_s,
          "lane_path" => lane_root&.to_s,
          "cwd" => workspace_root.to_s,
        }
      end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "agent flow: plan -> parallel tool calls -> join -> final transcript" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c010"

    user = nil
    planner = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Write code", metadata: {})
      planner = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "plan" })
      m.create_edge(from_node: user, to_node: planner, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::Task.node_type_key, ToolCallExecutor.new)
    registry.register(Messages::AgentMessage.node_type_key, PlanningAndFinalAgentExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [planner.id], claimed.map(&:id)
      DAG::Runner.run_node!(planner.id)

      tasks = graph.nodes.active.where(node_type: Messages::Task.node_type_key).order(:id).to_a
      assert_equal 2, tasks.length

      final = graph.nodes.active.find_by!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "final" })

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      tasks.each { |task| DAG::Runner.run_node!(task.id) }

      hash_task = tasks.find { |task| task.body_input["name"] == "hash_task" }
      array_task = tasks.find { |task| task.body_input["name"] == "array_task" }

      assert_equal "hash", hash_task.reload.metadata.dig("output_stats", "result_type")
      assert_equal 2, hash_task.metadata.dig("output_stats", "result_key_count")
      assert_equal "array", array_task.reload.metadata.dig("output_stats", "result_type")
      assert_equal 3, array_task.metadata.dig("output_stats", "result_array_len")

      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [final.id], claimed.map(&:id)
      DAG::Runner.run_node!(final.id)

      transcript = graph.transcript_for(final.id)
      assert_equal [user.id, final.id], transcript.map { |node| node.fetch("node_id") }

      context = graph.context_for(final.id)
      context_ids = context.map { |node| node.fetch("node_id") }
      [user.id, planner.id, hash_task.id, array_task.id, final.id].each do |node_id|
        assert_includes context_ids, node_id
      end

      included_ids = context_ids.index_with { |node_id| context_ids.index(node_id) }

      graph.edges.active.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES).each do |edge|
        next unless included_ids.key?(edge.from_node_id) && included_ids.key?(edge.to_node_id)

        assert_operator included_ids.fetch(edge.from_node_id), :<, included_ids.fetch(edge.to_node_id)
      end

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end

  test "tool failure propagation makes skipped message transcript-visible with a safe preview" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    turn_id = "0194f3c0-0000-7000-8000-00000000c011"

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      turn_id: turn_id,
      body_input: { "content" => "Do the thing" },
      metadata: {}
    )
    task = graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::ERRORED, turn_id: turn_id, metadata: { "error" => "boom" })
    character = graph.nodes.create!(node_type: Messages::CharacterMessage.node_type_key, state: DAG::Node::PENDING, turn_id: turn_id, metadata: { "actor" => "npc" })

    graph.edges.create!(from_node_id: user.id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: task.id, to_node_id: character.id, edge_type: DAG::Edge::DEPENDENCY)

    DAG::FailurePropagation.propagate!(graph: graph)

    character.reload
    assert_equal DAG::Node::SKIPPED, character.state
    assert_equal "blocked_by_failed_dependencies", character.metadata["reason"]

    transcript = graph.transcript_for(character.id)
    assert_equal [Messages::UserMessage.node_type_key, Messages::CharacterMessage.node_type_key], transcript.map { |node| node.fetch("node_type") }

    preview = transcript.last.dig("payload", "output_preview", "content").to_s
    assert_includes preview, "Skipped:"
    assert_includes preview, "blocked by failed dependencies"

    assert_equal [], DAG::GraphAudit.scan(graph: graph)
  end
end

class DAG::AgentOwnedToolCallsFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  class BundledClawToolProvider
    def initialize(workspace_root:, agent_root: nil, lane_root: nil, callback_session: nil)
      @workspace_root = workspace_root
      @agent_root = agent_root || workspace_root
      @lane_root = lane_root
      @callback_session = callback_session
      @application =
        Cybros::Agents::Claw::Application.new(
          source_root: Agents::BundledSources.path_for("claw"),
          deployment_fingerprint: "deployment:test-claw",
          required_bearer: "secret://agent",
        )
    end

    attr_reader :workspace_root, :agent_root, :lane_root

    def name = "programmable_agent"

    def execute_programmable_tool!(**payload)
      @application.call(
        method_name: "tool.execute",
        params: payload.deep_stringify_keys.merge(
          "session_context" => { "workspace" => workspace_payload },
          "execution_context" => { "workspace" => workspace_payload },
        ).tap do |params|
          params["callback_session"] = @callback_session if @callback_session.present?
        end,
      )
    end

    private

      def workspace_payload
        {
          "conversation_id" => "conversation:test",
          "root_path" => agent_root.to_s,
          "conversation_path" => workspace_root.to_s,
          "lane_path" => lane_root&.to_s,
          "cwd" => workspace_root.to_s,
        }
      end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "agent-owned edit and apply_patch results remain DAG-visible for follow-up agent steps" do
    with_agent_owned_task_runtime do |fixture|
      workspace_root = fixture.fetch(:workspace_root)
      FileUtils.mkdir_p(workspace_root.join("notes"))
      File.write(workspace_root.join("notes/todo.txt"), "before\nkeep\n", mode: "w", encoding: Encoding::UTF_8)

      edit_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "edit",
          tool_call_id: "tc_edit",
          arguments: {
            "path" => "notes/todo.txt",
            "old_text" => "before",
            "new_text" => "after",
          },
        )
      patch_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "apply_patch",
          tool_call_id: "tc_patch",
          arguments: {
            "patch" => <<~PATCH,
              --- notes/todo.txt
              +++ notes/todo.txt
              @@ -1,2 +1,2 @@
              -after
              +patched
               keep
            PATCH
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [edit_task, patch_task])

      assert_equal "patched\nkeep\n", File.read(workspace_root.join("notes/todo.txt"))

      edit_result = AgentCore::Resources::Tools::ToolResult.from_h(edit_task.reload.body_output.fetch("result"))
      patch_result = AgentCore::Resources::Tools::ToolResult.from_h(patch_task.reload.body_output.fetch("result"))

      refute edit_result.error?, edit_task.reload.body_output.inspect
      refute patch_result.error?, patch_task.reload.body_output.inspect
      assert_includes edit_task.body_output_preview.fetch("activity_preview"), "\"replacements\":1"
      assert_includes patch_task.body_output_preview.fetch("activity_preview"), "\"status\":\"modified\""

      tool_messages = tool_result_messages_for(fixture.fetch(:graph), fixture.fetch(:final_node).id)
      assert_equal 2, tool_messages.length
      assert_includes tool_messages.first.text, "[tool: edit]"
      assert_includes tool_messages.first.text, "\"replacements\":1"
      assert_includes tool_messages.second.text, "[tool: apply_patch]"
      assert_includes tool_messages.second.text, "\"status\":\"modified\""
      assert_equal [], DAG::GraphAudit.scan(graph: fixture.fetch(:graph))
    end
  end

  test "agent-owned exec results remain DAG-visible for follow-up agent steps" do
    with_agent_owned_task_runtime do |fixture|
      workspace_root = fixture.fetch(:workspace_root)
      FileUtils.mkdir_p(workspace_root.join("notes"))
      File.write(workspace_root.join("notes/todo.txt"), "workspace\n", mode: "w", encoding: Encoding::UTF_8)

      exec_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "exec",
          tool_call_id: "tc_exec",
          arguments: {
            "command" => "pwd && cat notes/todo.txt && >&2 echo warn",
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [exec_task])

      result = AgentCore::Resources::Tools::ToolResult.from_h(exec_task.reload.body_output.fetch("result"))
      refute result.error?, exec_task.reload.body_output.inspect

      assert_includes exec_task.body_output_preview.fetch("activity_preview"), "\"exit_code\":0"

      tool_message = tool_result_messages_for(fixture.fetch(:graph), fixture.fetch(:final_node).id).sole
      assert_includes tool_message.text, "[tool: exec]"
      assert_includes tool_message.text, "\"exit_code\":0"
      assert_includes tool_message.text, "\"stderr\":\"warn"
      raw_exec_output = JSON.parse(exec_task.reload.body_output.fetch("result").dig("content", 0, "text"))
      assert_includes raw_exec_output.fetch("stderr"), "warn"
      assert_equal [], DAG::GraphAudit.scan(graph: fixture.fetch(:graph))
    end
  end

  test "agent-owned exec uses the conversation cwd instead of the agent root or hidden lane path" do
    with_agent_owned_task_runtime do |fixture|
      workspace_root = fixture.fetch(:workspace_root)
      agent_root = fixture.fetch(:agent_root)
      lane_root = fixture.fetch(:lane_root)

      FileUtils.mkdir_p(workspace_root.join("notes"))
      FileUtils.mkdir_p(agent_root.join("notes"))
      FileUtils.mkdir_p(lane_root.join("notes"))

      File.write(workspace_root.join("notes", "todo.txt"), "conversation\n", mode: "w", encoding: Encoding::UTF_8)
      File.write(agent_root.join("notes", "todo.txt"), "root\n", mode: "w", encoding: Encoding::UTF_8)
      File.write(lane_root.join("notes", "todo.txt"), "lane\n", mode: "w", encoding: Encoding::UTF_8)

      exec_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "exec",
          tool_call_id: "tc_exec_cwd",
          arguments: {
            "command" => "pwd && cat notes/todo.txt",
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [exec_task])

      result = AgentCore::Resources::Tools::ToolResult.from_h(exec_task.reload.body_output.fetch("result"))
      refute result.error?, exec_task.reload.body_output.inspect

      output = JSON.parse(exec_task.reload.body_output.fetch("result").dig("content", 0, "text"))
      assert_includes output.fetch("stdout"), workspace_root.to_s
      assert_includes output.fetch("stdout"), "conversation"
      refute_includes output.fetch("stdout"), "root\n"
      refute_includes output.fetch("stdout"), "lane\n"
    end
  end

  test "agent-owned protected root paths deny AGENTS and history writes with host-level errors" do
    with_agent_owned_task_runtime do |fixture|
      agent_root = fixture.fetch(:agent_root)
      original_agents = File.read(agent_root.join("AGENTS.md"))

      agents_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "write",
          tool_call_id: "tc_write_agents",
          arguments: {
            "path" => "../../AGENTS.md",
            "content" => "hijack\n",
          },
        )
      history_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "write",
          tool_call_id: "tc_write_history",
          arguments: {
            "path" => "../../.history/SOUL.md",
            "content" => "scratch\n",
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [agents_task, history_task])

      agents_result = AgentCore::Resources::Tools::ToolResult.from_h(agents_task.reload.body_output.fetch("result"))
      history_result = AgentCore::Resources::Tools::ToolResult.from_h(history_task.reload.body_output.fetch("result"))

      assert agents_result.error?, agents_task.reload.body_output.inspect
      assert history_result.error?, history_task.reload.body_output.inspect
      assert_includes agents_result.text, "AGENTS.md"
      assert_includes agents_result.text, "read-only"
      assert_includes history_result.text, ".history"
      assert_includes history_result.text, "runtime-managed"
      assert_equal original_agents, File.read(agent_root.join("AGENTS.md"))
      refute agent_root.join(".history", "SOUL.md").exist?
    end
  end

  test "agent-owned exec denies protected root mutation attempts and leaves bootstrap files unchanged" do
    with_agent_owned_task_runtime do |fixture|
      agent_root = fixture.fetch(:agent_root)
      soul_path = agent_root.join("SOUL.md")
      original_soul = File.read(soul_path)

      exec_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "exec",
          tool_call_id: "tc_exec_protected_write",
          arguments: {
            "command" => "printf hacked > ../../SOUL.md",
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [exec_task])

      result = AgentCore::Resources::Tools::ToolResult.from_h(exec_task.reload.body_output.fetch("result"))
      assert result.error?, exec_task.reload.body_output.inspect
      assert_includes result.text, "exec"
      assert_includes result.text, "protected"
      assert_equal original_soul, File.read(soul_path)
    end
  end

  test "self-mutate skill edits snapshot history and refresh on the next top-level runtime only" do
    with_agent_owned_task_runtime do |fixture|
      conversation = fixture.fetch(:conversation)
      conversation.update!(metadata: { "agent" => {} })
      skill_path = fixture.fetch(:agent_root).join("skills/self-mutate/SKILL.md")
      original_skill = File.read(skill_path)
      updated_description = "Use when validating next-turn skill refresh after protected writes"
      updated_skill = replace_skill_description(original_skill, updated_description)

      first_node = conversation.append_user_message!(content: "First turn").fetch(:agent_node)
      first_runtime = build_cybros_runtime_for(node: first_node)
      original_description = skill_description_from_runtime(first_runtime, "self-mutate")

      provider_result =
        fixture.fetch(:runtime).provider.execute_programmable_tool!(
          tool_call_id: "tc_self_mutate_skill_write",
          logical_tool_name: "write",
          implementation_ref: "claw:write",
          arguments: {
            "path" => "../../skills/self-mutate/SKILL.md",
            "content" => updated_skill,
          },
        )

      write_result = AgentCore::Resources::Tools::ToolResult.from_h(provider_result.fetch("result"))
      refute write_result.error?, provider_result.inspect

      history_snapshots = Dir.glob(fixture.fetch(:agent_root).join(".history", "**", "skills", "self-mutate", "SKILL.md").to_s).sort
      assert history_snapshots.any?, "expected a skill snapshot under .history, got=#{Dir.glob(fixture.fetch(:agent_root).join(".history", "**", "*").to_s)}"
      assert_equal original_skill, File.read(history_snapshots.last)

      assert_equal original_description, skill_description_from_runtime(first_runtime, "self-mutate")

      second_node = conversation.append_user_message!(content: "Second turn").fetch(:agent_node)
      second_runtime = build_cybros_runtime_for(node: second_node)
      assert_equal updated_description, skill_description_from_runtime(second_runtime, "self-mutate")
    end
  end

  test "apply_patch deleting a protected skill file snapshots history before removal" do
    with_agent_owned_task_runtime do |fixture|
      skill_dir = fixture.fetch(:agent_root).join("skills/temporary-skill")
      FileUtils.mkdir_p(skill_dir)
      skill_path = skill_dir.join("SKILL.md")
      original_skill = <<~MD
        ---
        name: temporary-skill
        description: Temporary protected skill
        ---

        # Temporary Skill
      MD
      File.write(skill_path, original_skill, mode: "w", encoding: Encoding::UTF_8)

      apply_patch_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "apply_patch",
          tool_call_id: "tc_delete_skill_via_patch",
          arguments: {
            "patch" => <<~PATCH,
              *** Begin Patch
              *** Delete File: ../../skills/temporary-skill/SKILL.md
              *** End Patch
            PATCH
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [apply_patch_task])

      result = AgentCore::Resources::Tools::ToolResult.from_h(apply_patch_task.reload.body_output.fetch("result"))
      refute result.error?, apply_patch_task.reload.body_output.inspect
      refute skill_path.exist?

      history_snapshots = Dir.glob(fixture.fetch(:agent_root).join(".history", "**", "skills", "temporary-skill", "SKILL.md").to_s).sort
      assert history_snapshots.any?, "expected a protected delete snapshot under .history"
      assert_equal original_skill, File.read(history_snapshots.last)
    end
  end

  test "generic write-based skill creation does not create installer provenance metadata" do
    with_agent_owned_task_runtime do |fixture|
      write_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "write",
          tool_call_id: "tc_manual_skill_write",
          arguments: {
            "path" => "../../skills/manual-skill/SKILL.md",
            "content" => <<~MD,
              ---
              name: manual-skill
              description: Hand-authored skill
              ---

              # manual-skill
            MD
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [write_task])

      result = AgentCore::Resources::Tools::ToolResult.from_h(write_task.reload.body_output.fetch("result"))
      refute result.error?, write_task.reload.body_output.inspect
      assert_predicate fixture.fetch(:agent_root).join("skills/manual-skill/SKILL.md"), :file?
      refute_predicate fixture.fetch(:agent_root).join(".state/skills/manual-skill.json"), :exist?
    end
  end

  test "repo-root skill installs refresh the runtime on the next top-level turn only" do
    with_agent_owned_task_runtime(agent_tools: %w[write edit apply_patch exec memory_search memory_get memory_store skills_install]) do |fixture|
      conversation = fixture.fetch(:conversation)
      conversation.update!(metadata: { "agent" => {} })

      Dir.mktmpdir("cybros-local-skill-repo-") do |repo_root|
        write_skill_fixture!(Pathname.new(repo_root).join("skills"), name: "alpha-skill", description: "Alpha description")
        write_skill_fixture!(Pathname.new(repo_root).join("skills"), name: "beta-skill", description: "Beta description")

        first_node = conversation.append_user_message!(content: "First turn").fetch(:agent_node)
        first_runtime = build_cybros_runtime_for(node: first_node)
        first_skill_names = first_runtime.skills_store.list_skills.map(&:name)
        refute_includes first_skill_names, "alpha-skill"
        refute_includes first_skill_names, "beta-skill"

        provider_result =
          fixture.fetch(:runtime).provider.execute_programmable_tool!(
            tool_call_id: "tc_repo_root_batch_install",
            logical_tool_name: "skills_install",
            implementation_ref: "claw:skills_install",
            arguments: {
              "source_kind" => "github",
              "repo" => repo_root,
            },
          )

        install_result = AgentCore::Resources::Tools::ToolResult.from_h(provider_result.fetch("result"))
        refute install_result.error?, provider_result.inspect

        install_payload = JSON.parse(install_result.text)
        assert_equal "repo_root_batch", install_payload.fetch("mode")
        assert_equal 2, install_payload.fetch("installed_count")
        assert_equal true, install_payload.fetch("refresh_effective_on_next_top_level_turn")
        assert_predicate Agents::SkillsStoreBuilder.dirty_marker_path_for(agent: conversation.agent), :exist?

        assert_equal first_skill_names.sort, first_runtime.skills_store.list_skills.map(&:name).sort

        second_node = conversation.append_user_message!(content: "Second turn").fetch(:agent_node)
        second_runtime = build_cybros_runtime_for(node: second_node)
        second_skill_names = second_runtime.skills_store.list_skills.map(&:name)
        assert_includes second_skill_names, "alpha-skill"
        assert_includes second_skill_names, "beta-skill"
      end
    end
  end

  test "agent-owned memory tool results remain DAG-visible for follow-up agent steps" do
    with_agent_owned_task_runtime do |fixture|
      store_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "memory_store",
          tool_call_id: "tc_memory_store",
          arguments: {
            "content" => "Remember alpha",
          },
        )
      get_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "memory_get",
          tool_call_id: "tc_memory_get",
          arguments: { "scope" => "lane" },
        )
      search_task =
        create_agent_owned_task!(
          fixture: fixture,
          logical_tool_name: "memory_search",
          tool_call_id: "tc_memory_search",
          arguments: {
            "query" => "alpha",
          },
        )

      run_task_nodes!(fixture: fixture, tasks: [store_task, get_task, search_task])

      store_result = AgentCore::Resources::Tools::ToolResult.from_h(store_task.reload.body_output.fetch("result"))
      get_result = AgentCore::Resources::Tools::ToolResult.from_h(get_task.reload.body_output.fetch("result"))
      search_result = AgentCore::Resources::Tools::ToolResult.from_h(search_task.reload.body_output.fetch("result"))

      refute store_result.error?, store_task.reload.body_output.inspect
      refute get_result.error?, get_task.reload.body_output.inspect
      refute search_result.error?, search_task.reload.body_output.inspect
      assert_equal "lane", JSON.parse(store_task.reload.body_output.fetch("result").dig("content", 0, "text")).dig("document", "scope")
      assert_equal "lane", JSON.parse(get_task.reload.body_output.fetch("result").dig("content", 0, "text")).dig("document", "scope")
      assert_equal "lane", JSON.parse(search_task.reload.body_output.fetch("result").dig("content", 0, "text")).fetch("matches").first.fetch("scope")
      assert_includes store_task.body_output_preview.fetch("activity_preview"), "Remember alpha"
      assert_includes get_task.body_output_preview.fetch("activity_preview"), "Remember alpha"
      assert_includes search_task.body_output_preview.fetch("activity_preview"), "\"scope\":\"lane\""
      assert_includes search_task.body_output_preview.fetch("activity_preview"), "\"line\":1"

      tool_messages = tool_result_messages_for(fixture.fetch(:graph), fixture.fetch(:final_node).id)
      assert_equal 3, tool_messages.length
      assert_includes tool_messages.map(&:text).join("\n"), "[tool: memory_store]"
      assert_includes tool_messages.map(&:text).join("\n"), "[tool: memory_get]"
      assert_includes tool_messages.map(&:text).join("\n"), "[tool: memory_search]"
      assert_equal [], DAG::GraphAudit.scan(graph: fixture.fetch(:graph))
    end
  end

  private

    def with_agent_owned_task_runtime(agent_tools: %w[write edit apply_patch exec memory_search memory_get memory_store])
      isolated_workspace_root = nil
      workspace_root = nil
      agent_root = nil
      lane_root = nil
      callback = nil
      conversation = nil
      isolated_workspace_root = Dir.mktmpdir("agent-owned-tools-root-")

      with_default_agent_workspace_root(isolated_workspace_root) do
        conversation = create_conversation!(title: "Agent-owned tools")
        conversation.update!(
          permission_mode: "default",
          agent_config_schema_fingerprint: conversation.agent.config_schema_fingerprint,
        )

        workspace_descriptor = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
        workspace_root = Pathname.new(workspace_descriptor.fetch(:conversation_path))
        agent_root = Pathname.new(workspace_descriptor.fetch(:agent_root_path))
        lane_root = Pathname.new(Conversations::WorkspaceInitializer.lane_path_for(conversation: conversation, lane_id: conversation.chat_lane.id))
        FileUtils.mkdir_p(workspace_root)
        FileUtils.mkdir_p(lane_root)
        graph = conversation.root_graph
        turn_id = SecureRandom.uuid
        user = nil
        planner = nil
        final = nil

        graph.mutate!(turn_id: turn_id) do |m|
          user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Use coding tools", metadata: {})
          planner = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::FINISHED, content: "Working", metadata: {})
          final = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: { "phase" => "final" })
          m.create_edge(from_node: user, to_node: planner, edge_type: DAG::Edge::SEQUENCE)
        end

        runtime =
          AgentCore::DAG::Runtime.new(
            provider:
              BundledClawToolProvider.new(
                workspace_root: workspace_root,
                agent_root: agent_root,
                lane_root: lane_root,
                callback_session: callback_session_payload(callback = TestSupport::CallbackHarness.new.start),
              ),
            model: "dev/mock-model",
            tools_registry: AgentCore::Resources::Tools::Registry.new,
            tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
            llm_options: {},
            instrumenter: AgentCore::Observability::NullInstrumenter.new,
          )
        snapshot =
          Cybros::ProgrammableAgent::CapabilitySnapshot.build(
            kernel_registry_version: "kernel:v1",
            agent_key: "claw",
            agent_capabilities_version: "agent:v1",
            kernel_tools: [],
            agent_tools: Array(agent_tools).map do |logical_tool_name|
              {
                logical_tool_name: logical_tool_name,
                implementation_ref: "claw:#{logical_tool_name}",
              }
            end,
          )

        yield(
          conversation: conversation,
          graph: graph,
          runtime: runtime,
          planner_node: planner,
          final_node: final,
          workspace_root: workspace_root,
          agent_root: agent_root,
          lane_root: lane_root,
          snapshot: snapshot,
        )
      end
    ensure
      if conversation
        run_drafts = RunDraft.where(conversation_id: conversation.id)
        run_drafts.update_all(materialized_conversation_run_id: nil)
        run_drafts.delete_all
        ConversationRun.where(conversation_id: conversation.id).delete_all
        sessions = AgentRPCSession.where(conversation_id: conversation.id)
        invocations = AgentRPCInvocation.where(conversation_id: conversation.id)
        sessions.update_all(agent_rpc_invocation_id: nil)
        invocations.update_all(last_session_id: nil)
        invocations.delete_all
        sessions.delete_all
        conversation.destroy!
      end
      callback&.shutdown
      FileUtils.rm_rf(agent_root) if agent_root
      FileUtils.rm_rf(isolated_workspace_root) if isolated_workspace_root
    end

    def create_agent_owned_task!(fixture:, logical_tool_name:, tool_call_id:, arguments:)
      graph = fixture.fetch(:graph)
      planner = fixture.fetch(:planner_node)
      final = fixture.fetch(:final_node)
      route = fixture.fetch(:snapshot).route_for!(logical_tool_name)

      task =
        graph.nodes.create!(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: planner.lane_id,
          turn_id: planner.turn_id,
          metadata: {},
          body_input: {
            "logical_tool_name" => logical_tool_name,
            "requested_name" => logical_tool_name,
            "effective_tool_id" => route.effective_tool_id,
            "implementation_source" => "agent",
            "implementation_ref" => route.implementation_ref,
            "capability_registry_snapshot_id" => fixture.fetch(:snapshot).snapshot_id,
            "tool_surface_id" => "surface_agent_owned_tools",
            "tool_call_id" => tool_call_id,
            "arguments" => arguments,
            "arguments_summary" => JSON.generate(arguments),
          },
        )
      graph.edges.create!(from_node_id: planner.id, to_node_id: task.id, edge_type: DAG::Edge::SEQUENCE)
      graph.edges.create!(from_node_id: task.id, to_node_id: final.id, edge_type: DAG::Edge::DEPENDENCY)
      task
    end

    def run_task_nodes!(fixture:, tasks:)
      original_runtime_resolver = AgentCore::DAG.runtime_resolver
      original_registry = DAG.executor_registry

      DAG.executor_registry = DAG::ExecutorRegistry.new
      DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; fixture.fetch(:runtime) }

      claimed = DAG::Scheduler.claim_executable_nodes(graph: fixture.fetch(:graph), limit: 10, claimed_by: "test")
      assert_equal tasks.map(&:id), claimed.map(&:id)
      claimed.each { |task| DAG::Runner.run_node!(task.id) }
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end

    def tool_result_messages_for(graph, target_node_id)
      context = graph.context_for_full(target_node_id)
      AgentCore::DAG::ContextAdapter.new(context_nodes: context).call.messages.select(&:tool_result?)
    end

    def callback_session_payload(callback)
      {
        "endpoint" => callback.rpc_url,
        "bearer" => callback.required_bearer,
      }
    end

    def build_cybros_runtime_for(node:)
      Cybros::AgentRuntimeResolver.runtime_for(
        node: node,
        provider: Struct.new(:name).new("stub"),
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    end

    def replace_skill_description(source, description)
      source.sub(/^description:\s.*$/, "description: #{description}")
    end

    def skill_description_from_runtime(runtime, skill_name)
      runtime.skills_store.list_skills.find { |skill| skill.name == skill_name }.description
    end

    def write_skill_fixture!(root, name:, description:)
      skill_dir = Pathname.new(root).join(name)
      FileUtils.mkdir_p(skill_dir)
      File.write(
        skill_dir.join("SKILL.md"),
        <<~MD,
          ---
          name: #{name}
          description: #{description}
          ---

          # #{name}
        MD
      )
    end
end
