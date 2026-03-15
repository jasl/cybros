require "test_helper"
require "fileutils"
require "json"
require Rails.root.join("agents/claw/test/support/callback_harness")

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
    def initialize(workspace_root:, callback_session: nil)
      @workspace_root = workspace_root
      @callback_session = callback_session
      @application =
        Cybros::Agents::Claw::Application.new(
          source_root: Rails.root.join("agents/claw"),
          deployment_fingerprint: "deployment:test-claw",
          required_bearer: "secret://agent",
        )
    end

    attr_reader :workspace_root

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
          "logical_workspace_key" => "conversation-test",
          "logical_workspace_root_path" => workspace_root.to_s,
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
    def initialize(workspace_root:, callback_session: nil)
      @workspace_root = workspace_root
      @callback_session = callback_session
      @application =
        Cybros::Agents::Claw::Application.new(
          source_root: Rails.root.join("agents/claw"),
          deployment_fingerprint: "deployment:test-claw",
          required_bearer: "secret://agent",
        )
    end

    attr_reader :workspace_root

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
          "logical_workspace_key" => "conversation-test",
          "logical_workspace_root_path" => workspace_root.to_s,
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
      assert_includes exec_task.body_output_preview.fetch("activity_preview"), "\"stderr\":\"warn"

      tool_message = tool_result_messages_for(fixture.fetch(:graph), fixture.fetch(:final_node).id).sole
      assert_includes tool_message.text, "[tool: exec]"
      assert_includes tool_message.text, "\"exit_code\":0"
      assert_includes tool_message.text, "\"stderr\":\"warn"
      assert_equal [], DAG::GraphAudit.scan(graph: fixture.fetch(:graph))
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
          arguments: {},
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
      assert_includes store_task.body_output_preview.fetch("activity_preview"), "Remember alpha"
      assert_includes get_task.body_output_preview.fetch("activity_preview"), "Remember alpha"
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

    def with_agent_owned_task_runtime
      workspace_root = nil
      callback = nil
      conversation = create_conversation!(title: "Agent-owned tools")
      conversation.update!(
        permission_mode: "default",
        agent_config_schema_fingerprint: conversation.agent.config_schema_fingerprint,
      )

      workspace_root = Pathname.new(Conversations::WorkspaceInitializer.initialize!(conversation: conversation).fetch(:logical_workspace_root_path))
      graph = conversation.root_graph
      turn_id = "0194f3c0-0000-7000-8000-00000000c012"
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
          agent_tools: %w[edit apply_patch exec memory_search memory_get memory_store].map do |logical_tool_name|
            {
              logical_tool_name: logical_tool_name,
              implementation_ref: "claw:#{logical_tool_name}",
            }
          end,
        )

      yield(
        graph: graph,
        runtime: runtime,
        planner_node: planner,
        final_node: final,
        workspace_root: workspace_root,
        snapshot: snapshot,
      )
    ensure
      if conversation
        sessions = AgentRPCSession.where(conversation_id: conversation.id)
        invocations = AgentRPCInvocation.where(conversation_id: conversation.id)
        sessions.update_all(agent_rpc_invocation_id: nil)
        invocations.update_all(last_session_id: nil)
        invocations.delete_all
        sessions.delete_all
        conversation.destroy!
      end
      callback&.shutdown
      FileUtils.rm_rf(workspace_root) if workspace_root
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
end
