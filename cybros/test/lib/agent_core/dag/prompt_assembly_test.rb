require "test_helper"

class AgentCore::DAG::PromptAssemblyTest < ActiveSupport::TestCase
  test "build annotates visible tools with capability snapshot routing metadata" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = SecureRandom.uuid
    agent_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Continue the refactor.",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: registry_for(%w[compact_context cybros_shell_exec]),
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        execution_context_attributes: {
          cybros: {
            capability_snapshot: capability_snapshot_payload(
              agent_tools: [
                {
                  logical_tool_name: "compact_context",
                  implementation_ref: "agent://compact_context",
                },
              ],
              kernel_tools: [
                {
                  logical_tool_name: "cybros_shell_exec",
                  implementation_ref: "kernel://cybros_shell_exec",
                },
              ],
            ),
          },
        },
      )
    execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

    prompt =
      AgentCore::DAG::PromptAssembly.new(
        runtime: runtime,
        execution_context: execution_context,
      ).build(context_nodes: graph.context_for_full(agent_node.id))

    compact_context = prompt.tools.find { |tool| tool_value(tool, "name") == "compact_context" }
    shell_exec = prompt.tools.find { |tool| tool_value(tool, "name") == "cybros_shell_exec" }

    assert_equal "compact_context", tool_value(compact_context, "logical_tool_name")
    assert_match(/\Aetool_/, tool_value(compact_context, "effective_tool_id"))
    assert_equal "agent_program", tool_value(compact_context, "implementation_source")
    assert_equal "agent://compact_context", tool_value(compact_context, "implementation_ref")

    assert_equal "cybros_shell_exec", tool_value(shell_exec, "logical_tool_name")
    assert_match(/\Aetool_/, tool_value(shell_exec, "effective_tool_id"))
    assert_equal "kernel", tool_value(shell_exec, "implementation_source")
    assert_equal "kernel://cybros_shell_exec", tool_value(shell_exec, "implementation_ref")
  end

  test "build limits visible tools to the planning-owned tool surface manifest" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = SecureRandom.uuid
    agent_node = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Continue the refactor.",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    snapshot =
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_program_id: "agent-program-123",
        agent_program_version: "2026-03-11",
        kernel_tools: [
          {
            logical_tool_name: "cybros_shell_exec",
            implementation_ref: "kernel://cybros_shell_exec",
          },
        ],
        agent_tools: [
          {
            logical_tool_name: "compact_context",
            implementation_ref: "agent://compact_context",
          },
          {
            logical_tool_name: "memory_search",
            implementation_ref: "agent://memory_search",
          },
        ],
      )
    selected_tool = snapshot.route_for!("compact_context")
    manifest =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [selected_tool.effective_tool_id],
        tool_surface_label: "test-surface",
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: registry_for(%w[compact_context memory_search cybros_shell_exec]),
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        execution_context_attributes: {
          cybros: {
            capability_snapshot: capability_snapshot_payload(
              agent_tools: [
                {
                  logical_tool_name: "compact_context",
                  implementation_ref: "agent://compact_context",
                },
                {
                  logical_tool_name: "memory_search",
                  implementation_ref: "agent://memory_search",
                },
              ],
              kernel_tools: [
                {
                  logical_tool_name: "cybros_shell_exec",
                  implementation_ref: "kernel://cybros_shell_exec",
                },
              ],
            ),
            tool_surface: {
              "capability_registry_snapshot_id" => snapshot.snapshot_id,
              "tool_surface_id" => manifest.tool_surface_id,
              "tool_surface_label" => manifest.tool_surface_label,
              "selected_tool_ids" => manifest.selected_tool_ids,
              "logical_tool_names" => manifest.selected_tools.map(&:logical_tool_name),
            },
          },
        },
      )
    execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

    prompt =
      AgentCore::DAG::PromptAssembly.new(
        runtime: runtime,
        execution_context: execution_context,
      ).build(context_nodes: graph.context_for_full(agent_node.id))

    assert_equal ["compact_context"], prompt.tools.map { |tool| tool_value(tool, "name") }
  end

  test "build renders lane prompt buffer sections into the system prompt" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = SecureRandom.uuid
    agent_node = nil

    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "summaries",
      seq: 10,
      kind: "summary",
      content: "Older work was summarized.",
      priority: 100,
      estimated_tokens: 26,
      metadata: { "source" => "compact_context" },
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "working_notes",
      seq: 10,
      kind: "note",
      content: "Remember to preserve the edge cases.",
      priority: 50,
      estimated_tokens: 34,
      metadata: {},
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "handoff",
      content: "Pending review: merge the lane state task.",
      priority: 25,
      estimated_tokens: 40,
      metadata: {},
    )

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Continue the refactor.",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
      )
    execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

    prompt =
      AgentCore::DAG::PromptAssembly.new(
        runtime: runtime,
        execution_context: execution_context,
      ).build(context_nodes: graph.context_for_full(agent_node.id))

    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="summaries">)
    assert_includes prompt.system_prompt, "Older work was summarized."
    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="working_notes">)
    assert_includes prompt.system_prompt, "Remember to preserve the edge cases."
    assert_includes prompt.system_prompt, %(<lane_prompt_buffer name="handoff">)
    assert_includes prompt.system_prompt, "Pending review: merge the lane state task."
  end

  test "build can exclude selected lane prompt buffer sections while keeping the rest of the system prompt intact" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn_id = SecureRandom.uuid
    agent_node = nil

    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "summaries",
      seq: 10,
      kind: "summary",
      content: "Keep this summary.",
      priority: 100,
      estimated_tokens: 20,
      metadata: {},
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "working_notes",
      seq: 10,
      kind: "note",
      content: "Drop this working note first.",
      priority: 90,
      estimated_tokens: 28,
      metadata: {},
    )
    lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "handoff",
      content: "Keep this handoff.",
      priority: 80,
      estimated_tokens: 18,
      metadata: {},
    )

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "Continue the refactor.",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: lane.id,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Object.new,
        model: "test-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
      )
    execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

    prompt =
      AgentCore::DAG::PromptAssembly.new(
        runtime: runtime,
        execution_context: execution_context,
      ).build(
        context_nodes: graph.context_for_full(agent_node.id),
        excluded_prompt_buffer_names: ["working_notes"],
      )

    assert_includes prompt.system_prompt, "Keep this summary."
    refute_includes prompt.system_prompt, "Drop this working note first."
    assert_includes prompt.system_prompt, "Keep this handoff."
  end

  private

    def registry_for(tool_names)
      AgentCore::Resources::Tools::Registry.new.tap do |registry|
        Array(tool_names).each do |tool_name|
          registry.register(
            AgentCore::Resources::Tools::Tool.new(
              name: tool_name,
              description: tool_name,
              parameters: {},
            ) do
              AgentCore::Resources::Tools::ToolResult.success(text: tool_name)
            end
          )
        end
      end
    end

    def capability_snapshot_payload(agent_tools:, kernel_tools:)
      snapshot =
        Cybros::ProgrammableAgent::CapabilitySnapshot.build(
          kernel_registry_version: "kernel:v1",
          agent_program_id: "agent-program-123",
          agent_program_version: "2026-03-11",
          kernel_tools: kernel_tools,
          agent_tools: agent_tools,
        )

      {
        "capability_registry_snapshot_id" => snapshot.snapshot_id,
        "kernel_capability_registry_version" => snapshot.kernel_registry_version,
        "agent_capabilities_version" => snapshot.agent_program_version,
        "effective_tools" =>
          snapshot.effective_tools.map do |tool|
            {
              "logical_tool_name" => tool.logical_tool_name,
              "effective_tool_id" => tool.effective_tool_id,
              "implementation_source" => tool.implementation_source,
              "implementation_ref" => tool.implementation_ref,
            }
          end,
      }
    end

    def tool_value(tool, key)
      return nil unless tool.is_a?(Hash)
      return tool[key] if tool.key?(key)
      return tool[key.to_sym] if tool.key?(key.to_sym)

      nil
    end
end
