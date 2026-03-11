require "test_helper"

class Cybros::ProgrammableAgent::CapabilitySnapshotTest < ActiveSupport::TestCase
  test "merges kernel and agent tools with agent priority for non reserved names" do
    snapshot =
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_program_id: "agent-program-123",
        agent_program_version: "2026-03-11",
        kernel_tools: [
          tool(logical_tool_name: "compact_context", implementation_ref: "kernel://compact_context"),
          tool(logical_tool_name: "cybros_shell_exec", implementation_ref: "kernel://cybros_shell_exec"),
        ],
        agent_tools: [
          tool(logical_tool_name: "compact_context", implementation_ref: "agent://compact_context"),
          tool(logical_tool_name: "memory_search", implementation_ref: "agent://memory_search"),
        ],
      )

    compact_context = snapshot.route_for!("compact_context")
    memory_search = snapshot.route_for!("memory_search")
    cybros_shell_exec = snapshot.route_for!("cybros_shell_exec")

    assert_equal "agent_program", compact_context.implementation_source
    assert_equal "agent://compact_context", compact_context.implementation_ref

    assert_equal "agent_program", memory_search.implementation_source
    assert_equal "agent://memory_search", memory_search.implementation_ref

    assert_equal "kernel", cybros_shell_exec.implementation_source
    assert_equal "kernel://cybros_shell_exec", cybros_shell_exec.implementation_ref

    assert_match(/\Acsnap_/, snapshot.snapshot_id)
    assert_equal compact_context, snapshot.effective_tool(compact_context.effective_tool_id)
  end

  test "rejects agent tools under the reserved cybros namespace" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::CapabilitySnapshot.build(
          kernel_registry_version: "kernel:v1",
          agent_program_id: "agent-program-123",
          agent_program_version: "2026-03-11",
          kernel_tools: [],
          agent_tools: [
            tool(logical_tool_name: "cybros_shell_exec", implementation_ref: "agent://cybros_shell_exec"),
          ],
        )
      end

    assert_equal "cybros.programmable_agent.capability_snapshot.agent_tools_must_not_use_reserved_namespace", error.code
  end

  private

    def tool(logical_tool_name:, implementation_ref:)
      {
        logical_tool_name: logical_tool_name,
        implementation_ref: implementation_ref,
      }
    end
end
