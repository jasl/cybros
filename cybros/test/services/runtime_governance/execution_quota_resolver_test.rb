require "test_helper"

class RuntimeGovernance::ExecutionQuotaResolverTest < ActiveSupport::TestCase
  test "uses execution location quota facts when the target has no overrides" do
    target = create_execution_target!

    resolved = RuntimeGovernance::ExecutionQuotaResolver.resolve!(execution_target: target)

    assert_equal(
      {
        "scope_type" => "execution_location",
        "scope_id" => target.execution_location_id,
        "execution_location_id" => target.execution_location_id,
        "execution_target_id" => target.id,
        "override_applied" => false,
        "max_concurrent_tasks" => 4,
        "max_queued_tasks" => 16,
        "default_timeout_s" => 900,
        "cpu_limit_millicores" => nil,
        "memory_limit_mb" => nil,
      },
      resolved,
    )
  end

  test "uses execution target override facts when overrides are configured" do
    target =
      create_execution_target!(
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 5,
        default_timeout_s_override: 600,
        cpu_limit_millicores_override: 1500,
        memory_limit_mb_override: 2048,
      )

    resolved = RuntimeGovernance::ExecutionQuotaResolver.resolve!(execution_target: target)

    assert_equal(
      {
        "scope_type" => "execution_target",
        "scope_id" => target.id,
        "execution_location_id" => target.execution_location_id,
        "execution_target_id" => target.id,
        "override_applied" => true,
        "max_concurrent_tasks" => 2,
        "max_queued_tasks" => 5,
        "default_timeout_s" => 600,
        "cpu_limit_millicores" => 1500,
        "memory_limit_mb" => 2048,
      },
      resolved,
    )
  end

  private

  def create_execution_target!(attributes = {})
    location =
      ExecutionLocation.create!(
        name: "Fixture host #{SecureRandom.hex(4)}",
        kind: "host",
        platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: ["fixture"],
        max_concurrent_tasks: 4,
        max_queued_tasks: 16,
        default_timeout_s: 900,
      )
    workspace =
      Workspace.create!(
        execution_location: location,
        name: "Fixture workspace #{SecureRandom.hex(4)}",
        root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
        capability_tags: ["git"],
        tags: ["fixture"],
      )

    ExecutionTarget.create!(
      {
        execution_location: location,
        workspace: workspace,
        name: "Fixture target",
        status: "active",
        sandboxed: true,
      }.merge(attributes),
    )
  end
end
