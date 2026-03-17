require "test_helper"

class AgentTest < ActiveSupport::TestCase
  test "stores user-visible runtime config and execution-capacity policy" do
    program = create_program!
    target = create_execution_target!

    agent = materialize_agent_runtime!(agent: program, execution_profile: target)

    assert_equal program.name, agent.name
    assert_equal program.config_namespace, agent.config_namespace
    assert_equal program.published_contract_fingerprint, agent.published_contract_fingerprint
    assert_equal target.execution_location.max_concurrent_tasks, agent.max_concurrent_tasks
    assert_equal target.execution_location.max_queued_tasks, agent.max_queued_tasks
    assert_equal "agent", agent.execution_capacity_snapshot.fetch("scope_type")
    assert_equal agent.id, agent.execution_capacity_snapshot.fetch("scope_id")
  end

  test "updates the existing row when re-importing the same legacy program" do
    program = create_program!
    first_target = create_execution_target!(name: "Primary target", max_concurrent_tasks: 4)
    second_target = create_execution_target!(name: "Scaled target", max_concurrent_tasks: 9)

    first = materialize_agent_runtime!(agent: program, execution_profile: first_target)
    second = materialize_agent_runtime!(agent: program, execution_profile: second_target)

    assert_equal first.id, second.id
    assert_equal 9, second.max_concurrent_tasks
    assert_equal second_target.max_concurrent_tasks, second.execution_capacity_snapshot.fetch("max_concurrent_tasks")
  end

  test "restricts deletion when conversations still reference the agent" do
    program = create_program!
    target = create_execution_target!
    agent = materialize_agent_runtime!(agent: program, execution_profile: target)
    create_conversation!(agent: agent)

    assert_raises(ActiveRecord::DeleteRestrictionError) do
      agent.destroy!
    end
  end

  test "prefers agent-owned runtime surface config over the legacy program snapshot" do
    program = create_program!
    target = create_execution_target!
    agent = materialize_agent_runtime!(agent: program, execution_profile: target)

    program.update!(
      args: {
        "runtime_surface" => {
          "type" => "noop",
          "helpers" => { "estimate_tokens" => true },
        },
        "runtime_surface_status" => "configured",
      },
    )
    agent.update!(
      args: {
        "runtime_surface" => {
          "type" => "noop",
          "helpers" => { "estimate_messages" => true },
        },
        "runtime_surface_status" => "configured",
      },
    )

    assert_equal(
      {
        "type" => "noop",
        "helpers" => { "estimate_messages" => true },
      },
      agent.runtime_surface_config,
    )
    assert_equal "configured", agent.runtime_surface_status
  end

  test "workspace_root_path resolves under the configured agent workspace root" do
    workspace_root = Dir.mktmpdir("cybros-agent-model-")
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    with_default_agent_workspace_root(workspace_root) do
      assert_equal Pathname.new(workspace_root).join("bundled/claw").cleanpath, agent.workspace_root_path
      assert_equal agent.workspace_root_path, Agents::WorkspacePathResolver.resolve(agent: agent)
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  test "create_conversation helper rejects legacy agent_program and default_execution_target keywords" do
    program = create_program!
    target = create_execution_target!
    agent = materialize_agent_runtime!(agent: program, execution_profile: target)

    assert_raises(ArgumentError) do
      create_conversation!(agent: agent, agent_program: program, default_execution_target: target)
    end
  end

  test "runtime helper APIs reject legacy program and execution_target keywords" do
    program = create_program!
    target = create_execution_target!

    assert_raises(ArgumentError) do
      materialize_agent_runtime!(program: program, execution_target: target)
    end

    assert_raises(ArgumentError) do
      create_agent_runtime!(program: program, execution_target: target)
    end

    assert_raises(ArgumentError) do
      create_runtime_binding_record!(agent_program: program)
    end
  end

  private

    def create_program!
      create_agent_record!(
        name: "Fixture Program #{SecureRandom.hex(4)}",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "name" => "Fixture" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
        source_kind: "custom",
        local_path: "storage/agent_programs/#{SecureRandom.hex(4)}",
      )
    end

    def create_execution_target!(name: "Fixture target", max_concurrent_tasks: 4)
      location =
        create_execution_location_profile!(
          name: "#{name} host",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: max_concurrent_tasks,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        execution_location: location,
        workspace: workspace,
        name: name,
        status: "active",
        sandboxed: true,
      )
    end
end
