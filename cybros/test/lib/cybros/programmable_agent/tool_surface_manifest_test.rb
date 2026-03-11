require "test_helper"

class Cybros::ProgrammableAgent::ToolSurfaceManifestTest < ActiveSupport::TestCase
  test "reuses the runtime-surface manifest implementation as the single source of truth" do
    assert_same AgentCore::RuntimeSurface::ToolSurfaceManifest, Cybros::ProgrammableAgent::ToolSurfaceManifest
  end

  test "derives a stable tool surface id from selected tool ids regardless of selection order or label" do
    snapshot = build_snapshot
    first = snapshot.route_for!("compact_context")
    second = snapshot.route_for!("memory_search")

    manifest_a =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [first.effective_tool_id, second.effective_tool_id],
        tool_surface_label: "interactive",
      )

    manifest_b =
      Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
        capability_registry_snapshot: snapshot,
        selected_tool_ids: [second.effective_tool_id, first.effective_tool_id],
        tool_surface_label: "different-label",
      )

    assert_equal manifest_a.tool_surface_id, manifest_b.tool_surface_id
    assert_equal [first.effective_tool_id, second.effective_tool_id], manifest_a.selected_tool_ids
    assert_match(/\Asurface_/, manifest_a.tool_surface_id)
  end

  test "rejects selected tool ids that are not present in the snapshot" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
          capability_registry_snapshot: build_snapshot,
          selected_tool_ids: ["effective_tool:missing"],
        )
      end

    assert_equal "cybros.programmable_agent.tool_surface_manifest.selected_tool_ids_must_exist_in_snapshot", error.code
  end

  private

    def build_snapshot
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
    end
end
