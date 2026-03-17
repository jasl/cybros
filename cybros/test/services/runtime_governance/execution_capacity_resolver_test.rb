require "test_helper"

class RuntimeGovernance::ExecutionCapacityResolverTest < ActiveSupport::TestCase
  test "resolve! returns an agent-scoped snapshot without execution target identifiers" do
    agent = create_governed_agent!(max_concurrent_tasks: 2, max_queued_tasks: 5)

    snapshot = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent)

    assert_equal "agent", snapshot.fetch("scope_type")
    assert_equal agent.id, snapshot.fetch("scope_id")
    assert_equal 2, snapshot.fetch("max_concurrent_tasks")
    assert_equal 5, snapshot.fetch("max_queued_tasks")
    refute_includes snapshot.keys, "execution_target_id"
    refute_includes snapshot.keys, "execution_location_id"
  end

  test "resolve! preserves imported capacity overrides while keeping agent-scoped identity" do
    agent = create_governed_agent!(max_concurrent_tasks: 3, max_queued_tasks: 2)

    snapshot = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent)

    assert_equal "agent", snapshot.fetch("scope_type")
    assert_equal agent.id, snapshot.fetch("scope_id")
    assert_equal 3, snapshot.fetch("max_concurrent_tasks")
  end

  private

    def create_governed_agent!(max_concurrent_tasks: 4, max_queued_tasks: 16)
      create_agent_record!(
        name: "Fixture Agent #{SecureRandom.hex(4)}",
        config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
        manifest_snapshot: {},
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
      )
    end
end
