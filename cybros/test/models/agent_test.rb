require "test_helper"

class AgentTest < ActiveSupport::TestCase
  test "stores user-visible runtime config and execution-capacity policy" do
    agent_fixture = create_agent_fixture!(max_concurrent_tasks: 4, max_queued_tasks: 16)
    agent = materialize_agent_runtime!(agent: agent_fixture)

    assert_equal agent_fixture.name, agent.name
    assert_equal agent_fixture.config_namespace, agent.config_namespace
    assert_equal agent_fixture.published_contract_fingerprint, agent.published_contract_fingerprint
    assert_equal 4, agent.max_concurrent_tasks
    assert_equal 16, agent.max_queued_tasks
    assert_equal "agent", agent.execution_capacity_snapshot.fetch("scope_type")
    assert_equal agent.id, agent.execution_capacity_snapshot.fetch("scope_id")
  end

  test "rematerializing the same agent fixture keeps the same row and latest agent-owned capacity" do
    agent_fixture = create_agent_fixture!(max_concurrent_tasks: 4)
    first = materialize_agent_runtime!(agent: agent_fixture)

    agent_fixture.update!(max_concurrent_tasks: 9)
    second = materialize_agent_runtime!(agent: agent_fixture)

    assert_equal first.id, second.id
    assert_equal 9, second.max_concurrent_tasks
    assert_equal 9, second.execution_capacity_snapshot.fetch("max_concurrent_tasks")
  end

  test "restricts deletion when conversations still reference the agent" do
    agent = materialize_agent_runtime!(agent: create_agent_fixture!)
    create_conversation!(agent: agent)

    assert_raises(ActiveRecord::DeleteRestrictionError) do
      agent.destroy!
    end
  end

  test "prefers agent-owned runtime surface config over manifest snapshot defaults" do
    agent =
      materialize_agent_runtime!(
        agent:
          create_agent_fixture!(
            manifest_snapshot: {
              "name" => "Fixture Agent",
              "runtime_surface" => {
                "type" => "noop",
                "helpers" => { "estimate_tokens" => true },
              },
              "runtime_surface_status" => "configured",
            },
          ),
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
    legacy_agent = create_agent_fixture!
    legacy_execution_profile = Object.new

    assert_raises(ArgumentError) do
      create_conversation!(
        agent: legacy_agent,
        agent_program: legacy_agent,
        default_execution_target: legacy_execution_profile,
      )
    end
  end

  test "runtime helper APIs reject legacy program and execution_target keywords" do
    legacy_agent = create_agent_fixture!
    legacy_execution_profile = Object.new

    assert_raises(ArgumentError) do
      materialize_agent_runtime!(program: legacy_agent, execution_target: legacy_execution_profile)
    end

    assert_raises(ArgumentError) do
      create_agent_runtime!(program: legacy_agent, execution_target: legacy_execution_profile)
    end

    assert_raises(ArgumentError) do
      create_runtime_binding_record!(agent_program: legacy_agent)
    end
  end

  private

    def create_agent_fixture!(max_concurrent_tasks: 4, max_queued_tasks: 16, manifest_snapshot: nil)
      create_agent_record!(
        name: "Fixture Agent #{SecureRandom.hex(4)}",
        config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: manifest_snapshot || { "name" => "Fixture Agent" },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
        source_kind: "custom",
        local_path: "storage/agents/#{SecureRandom.hex(4)}",
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
      )
    end
end
