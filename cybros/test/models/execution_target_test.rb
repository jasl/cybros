require "test_helper"

class ExecutionTargetTest < ActiveSupport::TestCase
  test "requires workspace to belong to the same execution location" do
    local_location = create_location!(name: "Local")
    remote_location = create_location!(name: "Remote")
    remote_workspace = create_workspace!(execution_location: remote_location)

    target =
      build_target(
        execution_location: local_location,
        workspace: remote_workspace,
      )

    refute_predicate target, :valid?
    assert target.errors[:workspace].any?
  end

  test "validates quota override values when present" do
    location = create_location!(name: "Local")
    workspace = create_workspace!(execution_location: location)

    target =
      build_target(
        execution_location: location,
        workspace: workspace,
        max_concurrent_tasks_override: -1,
        default_timeout_s_override: 0,
      )

    refute_predicate target, :valid?
    assert target.errors[:max_concurrent_tasks_override].any?
    assert target.errors[:default_timeout_s_override].any?
  end

  private

  def create_location!(name:)
    ExecutionLocation.create!(
      name: name,
      kind: "host",
      platform: "macos_arm64",
      status: "active",
      trust_group: "operator",
      environment: "development",
      tags: %w[coding],
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
    )
  end

  def create_workspace!(execution_location:)
    Workspace.create!(
      execution_location: execution_location,
      name: "Repo",
      root_path: "/workspaces/#{execution_location.id}",
      workspace_type: "git",
      status: "active",
      capability_tags: %w[git ruby],
      tags: %w[app],
    )
  end

  def build_target(attributes = {})
    ExecutionTarget.new(
      {
        execution_location: attributes.fetch(:execution_location),
        workspace: attributes.fetch(:workspace),
        name: "Primary target",
        status: "active",
        sandboxed: true,
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: 6,
        default_timeout_s_override: 600,
        cpu_limit_millicores_override: 1_500,
        memory_limit_mb_override: 2_048,
      }.merge(attributes),
    )
  end
end
