require "test_helper"

class Cybros::ProgrammableAgent::CapabilitySnapshotTest < ActiveSupport::TestCase
  test "merges kernel and agent tools with agent priority for non reserved names" do
    snapshot =
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_key: "fixture-agent",
        agent_capabilities_version: "2026-03-11",
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

    assert_equal "agent", compact_context.implementation_source
    assert_equal "agent://compact_context", compact_context.implementation_ref

    assert_equal "agent", memory_search.implementation_source
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
          agent_key: "fixture-agent",
          agent_capabilities_version: "2026-03-11",
          kernel_tools: [],
          agent_tools: [
            tool(logical_tool_name: "cybros_shell_exec", implementation_ref: "agent://cybros_shell_exec"),
          ],
        )
      end

    assert_equal "cybros.programmable_agent.capability_snapshot.agent_tools_must_not_use_reserved_namespace", error.code
  end

  test "keeps subagent built-ins on kernel-owned routes even when agent catalogs try to override them" do
    snapshot =
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_key: "fixture-agent",
        agent_capabilities_version: "2026-03-17",
        kernel_tools: [
          tool(logical_tool_name: "subagent_spawn", implementation_ref: "kernel://subagent_spawn"),
          tool(logical_tool_name: "subagent_run", implementation_ref: "kernel://subagent_run", execution_mode: "parallel_safe"),
        ],
        agent_tools: [
          tool(logical_tool_name: "subagent_spawn", implementation_ref: "agent://subagent_spawn"),
          tool(logical_tool_name: "subagent_run", implementation_ref: "agent://subagent_run", execution_mode: "serial"),
        ],
      )

    spawn_route = snapshot.route_for!("subagent_spawn")
    run_route = snapshot.route_for!("subagent_run")

    assert_equal "kernel", spawn_route.implementation_source
    assert_equal "kernel://subagent_spawn", spawn_route.implementation_ref
    assert_equal "kernel", run_route.implementation_source
    assert_equal "kernel://subagent_run", run_route.implementation_ref
    assert_equal "parallel_safe", run_route.execution_mode
  end

  test "preserves execution_mode and defaults missing execution_mode to serial" do
    built =
      Cybros::ProgrammableAgent::CapabilitySnapshot.build(
        kernel_registry_version: "kernel:v1",
        agent_key: "fixture-agent",
        agent_capabilities_version: "2026-03-12",
        kernel_tools: [
          tool(logical_tool_name: "subagent_run", implementation_ref: "kernel://subagent_run", execution_mode: "parallel_safe"),
          tool(logical_tool_name: "cybros_generate_title", implementation_ref: "kernel://cybros_generate_title"),
        ],
        agent_tools: [],
      )

    restored =
      Cybros::ProgrammableAgent::CapabilitySnapshot.restore(
        "capability_registry_snapshot_id" => built.snapshot_id,
        "kernel_capability_registry_version" => built.kernel_registry_version,
        "agent_key" => built.agent_key,
        "agent_capabilities_version" => built.agent_capabilities_version,
        "effective_tools" =>
          built.effective_tools.map do |tool|
            {
              "logical_tool_name" => tool.logical_tool_name,
              "effective_tool_id" => tool.effective_tool_id,
              "implementation_source" => tool.implementation_source,
              "implementation_ref" => tool.implementation_ref,
              "execution_mode" => tool.execution_mode,
            }
          end,
      )

    assert_equal "parallel_safe", restored.route_for!("subagent_run").execution_mode
    assert_equal "serial", restored.route_for!("cybros_generate_title").execution_mode
  end

  private

    def tool(logical_tool_name:, implementation_ref:, execution_mode: nil)
      {
        logical_tool_name: logical_tool_name,
        implementation_ref: implementation_ref,
        execution_mode: execution_mode,
      }
    end
end
