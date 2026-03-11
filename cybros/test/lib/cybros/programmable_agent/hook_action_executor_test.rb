require "test_helper"

class Cybros::ProgrammableAgent::HookActionExecutorTest < ActiveSupport::TestCase
  test "create_task append materializes a routed follow-up task chain from the pinned conversation run snapshot" do
    conversation = create_conversation!(title: "Hook action append")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("subagent_spawn")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-agent-priority",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    Cybros::ProgrammableAgent::HookActionExecutor.execute!(
      hook_name: "after_task_notice",
      conversation_run: run,
      actions: [
        Cybros::ProgrammableAgent::HookActions::CreateTask.new(
          type: "create_task",
          logical_tool_name: "subagent_spawn",
          input: { "name" => "Helper", "prompt" => "Summarize this" },
          placement: "append",
          metadata: nil,
        ),
      ],
      placeholder_node: agent_node,
    )

    tasks =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .order(:id)
        .to_a
    assert_equal 1, tasks.size

    task = tasks.first
    assert_equal DAG::Node::PENDING, task.state
    assert_equal "subagent_spawn", task.body_input.fetch("requested_name")
    assert_equal "subagent_spawn", task.body_input.fetch("logical_tool_name")
    assert_equal route.effective_tool_id, task.body_input.fetch("effective_tool_id")
    assert_equal route.implementation_source, task.body_input.fetch("implementation_source")
    assert_equal route.implementation_ref, task.body_input.fetch("implementation_ref")
    assert_equal snapshot.snapshot_id, task.body_input.fetch("capability_registry_snapshot_id")
    assert_equal tool_surface.tool_surface_id, task.body_input.fetch("tool_surface_id")
    assert_equal({ "name" => "Helper", "prompt" => "Summarize this" }, task.body_input.fetch("arguments"))

    continuation_nodes =
      conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .to_a
    assert_equal 1, continuation_nodes.size

    continuation = continuation_nodes.first
    assert_equal DAG::Node::PENDING, continuation.state
    assert conversation.root_graph.edges.exists?(
      from_node_id: agent_node.id,
      to_node_id: task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.exists?(
      from_node_id: task.id,
      to_node_id: continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
  end

  test "emit_message returns a final assistant payload while preserving the current placeholder node" do
    conversation = create_conversation!(title: "Hook action executor")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    result =
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "before_finalize_output",
        actions: [
          Cybros::ProgrammableAgent::HookActions::SetStepStatus.new(type: "set_step_status", text: "Finishing", state: "running"),
          Cybros::ProgrammableAgent::HookActions::EmitMessage.new(
            type: "emit_message",
            message: { "role" => "assistant", "content" => "Final reply" },
          ),
        ],
        placeholder_node: agent_node,
      )

    assert_equal({ "role" => "assistant", "content" => "Final reply" }, result.emitted_message)
    assert_equal "Finishing", agent_node.reload.body_output_preview.fetch("content")
    assert_equal DAG::Node::PENDING, agent_node.state
  end

  test "halt returns a terminal action without mutating the placeholder immediately" do
    conversation = create_conversation!(title: "Hook action halt")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    result =
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "before_finalize_output",
        actions: [
          Cybros::ProgrammableAgent::HookActions::Halt.new(
            type: "halt",
            reason: "agent_declined_turn",
            message: "Agent declined to continue",
          ),
        ],
        placeholder_node: agent_node,
      )

    assert_nil result.emitted_message
    assert_equal "halt", result.terminal_action.type
    assert_equal "agent_declined_turn", result.terminal_action.reason
    assert_equal "Agent declined to continue", result.terminal_action.message
    assert_equal DAG::Node::RUNNING, agent_node.reload.state
  end

  test "append follow-up tasks can target a task anchor while updating the parent placeholder" do
    conversation = create_conversation!(title: "Hook action task anchor")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil
    task_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
          body_input: {
            "name" => "subagent_wait",
            "requested_name" => "subagent_wait",
            "tool_call_id" => "tc_wait_anchor",
            "arguments" => { "subagent_id" => SecureRandom.uuid },
            "arguments_summary" => "{}",
          },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("subagent_spawn")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-after-subagent-result",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    Cybros::ProgrammableAgent::HookActionExecutor.execute!(
      hook_name: "after_subagent_result",
      conversation_run: run,
      actions: [
        Cybros::ProgrammableAgent::HookActions::SetStepStatus.new(type: "set_step_status", text: "Summarizing subagent", state: "running"),
        Cybros::ProgrammableAgent::HookActions::CreateTask.new(
          type: "create_task",
          logical_tool_name: "subagent_spawn",
          input: { "name" => "Helper", "prompt" => "Follow up on the result" },
          placement: "append",
          metadata: { "source" => "after_subagent_result" },
        ),
      ],
      placeholder_node: agent_node,
      anchor_node: task_node,
    )

    appended_task =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .where.not(id: task_node.id)
        .order(:id)
        .sole
    continuation =
      conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .sole

    assert_equal "Summarizing subagent", agent_node.reload.body_output_preview.fetch("content")
    assert_equal task_node.id, appended_task.metadata.fetch("source_node_id")
    assert_equal({ "source" => "after_subagent_result" }, appended_task.metadata.fetch("authored_metadata"))
    assert conversation.root_graph.edges.exists?(
      from_node_id: task_node.id,
      to_node_id: appended_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.exists?(
      from_node_id: appended_task.id,
      to_node_id: continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    refute conversation.root_graph.edges.exists?(
      from_node_id: agent_node.id,
      to_node_id: appended_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
  end

  test "append follow-up tasks on a task anchor reuse an existing continuation agent instead of creating a duplicate" do
    conversation = create_conversation!(title: "Hook action task append splice")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil
    task_node = nil
    existing_continuation = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
          body_input: {
            "name" => "subagent_wait",
            "requested_name" => "subagent_wait",
            "tool_call_id" => "tc_wait_existing_continuation",
            "arguments" => { "subagent_id" => SecureRandom.uuid },
            "arguments_summary" => "{}",
          },
        )

      existing_continuation =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "generated_by" => "agent_core.tool_loop" },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task_node, to_node: existing_continuation, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("subagent_spawn")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-after-subagent-result-splice",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    Cybros::ProgrammableAgent::HookActionExecutor.execute!(
      hook_name: "after_subagent_result",
      conversation_run: run,
      actions: [
        Cybros::ProgrammableAgent::HookActions::CreateTask.new(
          type: "create_task",
          logical_tool_name: "subagent_spawn",
          input: { "name" => "Helper", "prompt" => "Follow up on the result" },
          placement: "append",
          metadata: { "source" => "after_subagent_result" },
        ),
      ],
      placeholder_node: agent_node,
      anchor_node: task_node,
    )

    appended_task =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .where.not(id: task_node.id)
        .order(:id)
        .sole
    continuations =
      conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .to_a

    assert_equal [existing_continuation.id], continuations.map(&:id)
    assert conversation.root_graph.edges.exists?(
      from_node_id: task_node.id,
      to_node_id: appended_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.exists?(
      from_node_id: appended_task.id,
      to_node_id: existing_continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    refute conversation.root_graph.edges.active.exists?(
      from_node_id: task_node.id,
      to_node_id: existing_continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.where(
      from_node_id: task_node.id,
      to_node_id: existing_continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    ).where.not(compressed_at: nil).exists?
  end

  test "append continuation splice remains idempotent across repeated hook execution" do
    conversation = create_conversation!(title: "Hook action task append splice replay")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil
    task_node = nil
    existing_continuation = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
          body_input: {
            "name" => "subagent_wait",
            "requested_name" => "subagent_wait",
            "tool_call_id" => "tc_wait_splice_replay",
            "arguments" => { "subagent_id" => SecureRandom.uuid },
            "arguments_summary" => "{}",
          },
        )

      existing_continuation =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: { "generated_by" => "agent_core.tool_loop" },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: task_node, to_node: existing_continuation, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("subagent_spawn")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-after-subagent-result-splice-replay",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    2.times do
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "after_subagent_result",
        conversation_run: run,
        actions: [
          Cybros::ProgrammableAgent::HookActions::CreateTask.new(
            type: "create_task",
            logical_tool_name: "subagent_spawn",
            input: { "name" => "Helper", "prompt" => "Follow up on the result" },
            placement: "append",
            metadata: { "source" => "after_subagent_result" },
          ),
        ],
        placeholder_node: agent_node,
        anchor_node: task_node,
      )
    end

    appended_tasks =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .where.not(id: task_node.id)
        .order(:id)
        .to_a
    continuations =
      conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .to_a

    assert_equal 1, appended_tasks.size
    assert_equal [existing_continuation.id], continuations.map(&:id)
    assert conversation.root_graph.edges.active.exists?(
      from_node_id: task_node.id,
      to_node_id: appended_tasks.first.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.active.exists?(
      from_node_id: appended_tasks.first.id,
      to_node_id: existing_continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    refute conversation.root_graph.edges.active.exists?(
      from_node_id: task_node.id,
      to_node_id: existing_continuation.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
  end

  test "prepend tasks on a task anchor defer the current tool into a cloned continuation" do
    conversation = create_conversation!(title: "Hook action prepend")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil
    task_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )

      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "task-metadata" },
          body_input: {
            "name" => "subagent_run",
            "requested_name" => "subagent_run",
            "tool_call_id" => "tc_spawn_anchor",
            "arguments" => { "name" => "researcher", "prompt" => "Investigate the repo" },
            "arguments_summary" => "{\"name\":\"researcher\",\"prompt\":\"Investigate the repo\"}",
          },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("compact_context")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-before-subagent-spawn",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    result =
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "before_subagent_spawn",
        conversation_run: run,
        actions: [
          Cybros::ProgrammableAgent::HookActions::SetStepStatus.new(type: "set_step_status", text: "Compacting context", state: "running"),
          Cybros::ProgrammableAgent::HookActions::CreateTask.new(
            type: "create_task",
            logical_tool_name: "compact_context",
            input: { "reason" => "subagent_spawn_guard" },
            placement: "prepend",
            metadata: { "source" => "before_subagent_spawn" },
          ),
        ],
        placeholder_node: agent_node,
        anchor_node: task_node,
      )

    tasks =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .where.not(id: task_node.id)
        .order(:id)
        .to_a

    prepended_task, deferred_task = tasks

    assert_equal true, result.deferred_anchor
    assert_nil result.emitted_message
    assert_nil result.terminal_action
    assert_equal "Compacting context", agent_node.reload.body_output_preview.fetch("content")
    assert_equal "compact_context", prepended_task.body_input.fetch("requested_name")
    assert_equal task_node.id, prepended_task.metadata.fetch("source_node_id")
    assert_equal({ "source" => "before_subagent_spawn" }, prepended_task.metadata.fetch("authored_metadata"))
    assert_equal DAG::Node::PENDING, deferred_task.state
    assert_equal "subagent_run", deferred_task.body_input.fetch("requested_name")
    assert_equal task_node.body_input.fetch("requested_name"), deferred_task.body_input.fetch("requested_name")
    assert_equal task_node.body_input.fetch("arguments"), deferred_task.body_input.fetch("arguments")
    refute_equal task_node.body_input.fetch("tool_call_id"), deferred_task.body_input.fetch("tool_call_id")
    assert_equal "task-metadata", deferred_task.metadata.fetch("existing")
    assert_equal task_node.id, deferred_task.metadata.fetch("deferred_from_node_id")
    assert_equal task_node.body_input.fetch("tool_call_id"), deferred_task.metadata.fetch("deferred_from_tool_call_id")
    assert conversation.root_graph.edges.exists?(
      from_node_id: task_node.id,
      to_node_id: prepended_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.exists?(
      from_node_id: prepended_task.id,
      to_node_id: deferred_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    refute conversation.root_graph.nodes.where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id).where.not(id: agent_node.id).exists?
  end

  test "prepend task routing can recover the pinned conversation run from the task anchor turn" do
    conversation = create_conversation!(title: "Hook action prepend lookup")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil
    task_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      task_node =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
          body_input: {
            "name" => "subagent_run",
            "requested_name" => "subagent_run",
            "tool_call_id" => "tc_spawn_lookup",
            "arguments" => { "name" => "researcher", "prompt" => "Investigate the repo" },
            "arguments_summary" => "{\"name\":\"researcher\",\"prompt\":\"Investigate the repo\"}",
          },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: agent_node, to_node: task_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("compact_context")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-before-subagent-spawn-lookup",
      )
    create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    result =
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "before_subagent_spawn",
        actions: [
          Cybros::ProgrammableAgent::HookActions::CreateTask.new(
            type: "create_task",
            logical_tool_name: "compact_context",
            input: { "reason" => "subagent_spawn_guard" },
            placement: "prepend",
            metadata: nil,
          ),
        ],
        placeholder_node: agent_node,
        anchor_node: task_node,
      )

    assert_equal true, result.deferred_anchor
    assert_equal 3, conversation.root_graph.nodes.where(node_type: Messages::Task.node_type_key, turn_id: turn_id).count
  end

  test "prepend tasks on a live agent anchor defer the current step into a cloned continuation" do
    conversation = create_conversation!(title: "Hook action agent prepend")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    agent_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: { "existing" => "agent-metadata" },
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("compact_context")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-on-context-pressure",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: agent_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    result =
      Cybros::ProgrammableAgent::HookActionExecutor.execute!(
        hook_name: "on_context_pressure",
        conversation_run: run,
        actions: [
          Cybros::ProgrammableAgent::HookActions::SetStepStatus.new(type: "set_step_status", text: "Compacting context", state: "running"),
          Cybros::ProgrammableAgent::HookActions::CreateTask.new(
            type: "create_task",
            logical_tool_name: "compact_context",
            input: { "reason" => "soft_limit_reached" },
            placement: "prepend",
            metadata: { "source" => "on_context_pressure" },
          ),
        ],
        placeholder_node: agent_node,
        anchor_node: agent_node,
      )

    prepended_task =
      conversation.root_graph.nodes
        .where(node_type: Messages::Task.node_type_key, turn_id: turn_id)
        .order(:id)
        .sole
    deferred_agent =
      conversation.root_graph.nodes
        .where(node_type: Messages::AgentMessage.node_type_key, turn_id: turn_id)
        .where.not(id: agent_node.id)
        .order(:id)
        .sole

    assert_equal true, result.deferred_anchor
    assert_nil result.emitted_message
    assert_nil result.terminal_action
    assert_equal "Compacting context", agent_node.reload.body_output_preview.fetch("content")
    assert_equal "compact_context", prepended_task.body_input.fetch("requested_name")
    assert_equal agent_node.id, prepended_task.metadata.fetch("source_node_id")
    assert_equal({ "source" => "on_context_pressure" }, prepended_task.metadata.fetch("authored_metadata"))
    assert_equal DAG::Node::PENDING, deferred_agent.state
    assert_equal "agent-metadata", deferred_agent.metadata.fetch("existing")
    assert_equal agent_node.id, deferred_agent.metadata.fetch("deferred_from_node_id")
    assert conversation.root_graph.edges.exists?(
      from_node_id: agent_node.id,
      to_node_id: prepended_task.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
    assert conversation.root_graph.edges.exists?(
      from_node_id: prepended_task.id,
      to_node_id: deferred_agent.id,
      edge_type: DAG::Edge::SEQUENCE,
    )
  end

  test "agent-anchor prepend rejects mismatched placeholder and anchor nodes" do
    conversation = create_conversation!(title: "Hook action agent prepend mismatch")
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    placeholder_node = nil
    other_agent_node = nil

    conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      placeholder_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )

      other_agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: placeholder_node, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: placeholder_node, to_node: other_agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    program = create_program!
    snapshot = build_capability_snapshot(program_id: program.id)
    route = snapshot.route_for!("compact_context")
    tool_surface =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [route.effective_tool_id],
        tool_surface_label: "fixture-on-context-pressure-mismatch",
      )
    run = create_conversation_run!(conversation: conversation, dag_node_id: placeholder_node.id, program: program, snapshot: snapshot, tool_surface: tool_surface)

    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::HookActionExecutor.execute!(
          hook_name: "on_context_pressure",
          conversation_run: run,
          actions: [
            Cybros::ProgrammableAgent::HookActions::CreateTask.new(
              type: "create_task",
              logical_tool_name: "compact_context",
              input: { "reason" => "soft_limit_reached" },
              placement: "prepend",
              metadata: nil,
            ),
          ],
          placeholder_node: placeholder_node,
          anchor_node: other_agent_node,
        )
      end

    assert_equal "cybros.programmable_agent.runtime.prepend_requires_current_step_anchor", error.code
  end

  private

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_active_deployment!(program:, capability_snapshot:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:9999/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        transport_config: {},
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: capability_snapshot_payload(capability_snapshot),
        inspection_details: {
          "identity" => {
            "deployment_fingerprint" => "fixture-deployment-v1",
          },
        },
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_conversation_run!(conversation:, dag_node_id:, program:, snapshot:, tool_surface:)
      deployment = create_active_deployment!(program: program, capability_snapshot: snapshot)

      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: dag_node_id,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        initiated_by_user: conversation.user,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: program.published_contract_fingerprint,
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
        effective_policy: {},
        runtime_governors: {
          "provider_limiter" => {
            "provider_key" => "openai",
          },
        },
        snapshot: {
          "capability_snapshot" => capability_snapshot_payload(snapshot),
          "draft" => {
            "id" => SecureRandom.uuid,
            "planning" => {
              "step_plan" => { "summary" => "fixture summary" },
              "tool_surface" => tool_surface_payload(tool_surface, snapshot: snapshot),
            },
          },
        },
      )
    end

    def build_capability_snapshot(program_id:)
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_program_id: program_id,
        agent_program_version: "agent:v1",
        kernel_tools: [
          {
            logical_tool_name: "compact_context",
            implementation_ref: "kernel://compact_context",
          },
        ],
        agent_tools: [
          {
            logical_tool_name: "subagent_spawn",
            implementation_ref: "agent://subagent_spawn",
          },
        ],
      )
    end

    def capability_snapshot_payload(snapshot)
      {
        "capability_registry_snapshot_id" => snapshot.snapshot_id,
        "kernel_capability_registry_version" => snapshot.kernel_registry_version,
        "agent_program_id" => snapshot.agent_program_id,
        "agent_capabilities_version" => snapshot.agent_program_version,
        "effective_tools" => snapshot.effective_tools.map { |tool| effective_tool_payload(tool) },
      }
    end

    def tool_surface_payload(tool_surface, snapshot:)
      {
        "capability_registry_snapshot_id" => snapshot.snapshot_id,
        "selected_tool_ids" => tool_surface.selected_tool_ids,
        "tool_surface_label" => tool_surface.tool_surface_label,
        "tool_surface_id" => tool_surface.tool_surface_id,
        "logical_tool_names" => tool_surface.selected_tools.map(&:logical_tool_name),
      }
    end

    def effective_tool_payload(tool)
      {
        "logical_tool_name" => tool.logical_tool_name,
        "effective_tool_id" => tool.effective_tool_id,
        "implementation_source" => tool.implementation_source,
        "implementation_ref" => tool.implementation_ref,
      }
    end
end
