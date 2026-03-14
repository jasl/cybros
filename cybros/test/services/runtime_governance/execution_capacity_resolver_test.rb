require "test_helper"

class RuntimeGovernance::ExecutionCapacityResolverTest < ActiveSupport::TestCase
  test "resolve! returns an agent-scoped snapshot without execution target identifiers" do
    program = create_program!
    target = create_execution_target!(max_concurrent_tasks: 2, max_queued_tasks: 5)
    agent = materialize_agent_runtime!(program: program, execution_target: target)

    snapshot = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent)

    assert_equal "agent", snapshot.fetch("scope_type")
    assert_equal agent.id, snapshot.fetch("scope_id")
    assert_equal 2, snapshot.fetch("max_concurrent_tasks")
    assert_equal 5, snapshot.fetch("max_queued_tasks")
    refute_includes snapshot.keys, "execution_target_id"
    refute_includes snapshot.keys, "execution_location_id"
  end

  test "resolve! preserves imported capacity overrides while keeping agent-scoped identity" do
    program = create_program!
    target =
      create_execution_target!(
        max_concurrent_tasks: 1,
        max_queued_tasks: 2,
        max_concurrent_tasks_override: 3,
      )
    agent = materialize_agent_runtime!(program: program, execution_target: target)

    snapshot = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent)

    assert_equal "agent", snapshot.fetch("scope_type")
    assert_equal agent.id, snapshot.fetch("scope_id")
    assert_equal 3, snapshot.fetch("max_concurrent_tasks")
  end

  private

    def create_program!
      create_agent_record!(
        name: "Fixture Program #{SecureRandom.hex(4)}",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
      )
    end

    def create_execution_target!(max_concurrent_tasks:, max_queued_tasks:, **overrides)
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: max_concurrent_tasks,
          max_queued_tasks: max_queued_tasks,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Fixture workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        {
          execution_location: location,
          workspace: workspace,
          name: "Fixture target",
          status: "active",
          sandboxed: true,
        }.merge(overrides),
      )
    end
end
