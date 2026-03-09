require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "belongs to an execution location" do
    workspace = build_workspace(execution_location: nil)

    refute_predicate workspace, :valid?
    assert_includes workspace.errors[:execution_location], "must exist"
  end

  test "enforces root_path uniqueness within one execution location" do
    location = create_location!(name: "Workstation")
    build_workspace(execution_location: location).save!

    duplicate = build_workspace(execution_location: location, name: "Mirror")

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:root_path], "has already been taken"

    other_location = create_location!(name: "Remote VM")
    other_workspace = build_workspace(execution_location: other_location)

    assert_predicate other_workspace, :valid?
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

  def build_workspace(attributes = {})
    Workspace.new(
      {
        execution_location: attributes.key?(:execution_location) ? attributes[:execution_location] : create_location!(name: "Default host"),
        name: "Repo",
        root_path: "/workspaces/cybros",
        workspace_type: "git",
        status: "active",
        capability_tags: %w[git ruby],
        tags: %w[app],
      }.merge(attributes),
    )
  end
end
