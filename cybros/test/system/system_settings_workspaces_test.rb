require "application_system_test_case"

class SystemSettingsWorkspacesSystemTest < ApplicationSystemTestCase
  teardown do
    destroy_created_execution_inventory!
  end

  test "operator can open a workspace from the execution target surface and edit operator fields" do
    owner = create_user!(email: "owner-workspaces@example.com")
    location = create_execution_location!(name: "Primary host")
    workspace = create_workspace!(execution_location: location, name: "Primary workspace")
    target = create_execution_target!(execution_location: location, workspace: workspace, name: "Primary target")

    sign_in_as!(email: owner.identity.email)
    visit system_settings_execution_target_path(target)

    click_link workspace.root_path
    assert_current_path system_settings_workspace_path(workspace)
    assert_text "Workspace"
    click_link "Edit workspace"

    assert_current_path edit_system_settings_workspace_path(workspace)
    select "Inactive", from: "Status"
    fill_in "Capability tags", with: "git, ruby, shell"
    fill_in "Safety tags", with: "protected, fixture"

    click_button "Save workspace"

    assert_current_path system_settings_workspace_path(workspace)
    assert_text "Workspace updated"
    assert_text "inactive"
    assert_text "git, ruby, shell"
    assert_text "protected, fixture"
  end

  test "operator can open a workspace from the execution location surface" do
    owner = create_user!(email: "owner-location-workspaces@example.com")
    location = create_execution_location!(name: "Linked host")
    workspace = create_workspace!(execution_location: location, name: "Linked workspace")

    sign_in_as!(email: owner.identity.email)
    visit system_settings_execution_location_path(location)

    click_link workspace.name

    assert_current_path system_settings_workspace_path(workspace)
    assert_text location.name
    assert_text workspace.root_path
  end

  private

    def destroy_created_execution_inventory!
      Array(@created_execution_targets).reverse_each(&:destroy!)
      Array(@created_workspaces).reverse_each(&:destroy!)
      Array(@created_execution_locations).reverse_each(&:destroy!)
    end

    def create_execution_location!(name:)
      location =
        ExecutionLocation.create!(
          name: name,
          kind: "host",
          platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: ["fixture", "interactive"],
        max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      (@created_execution_locations ||= []) << location
      location
    end

    def create_workspace!(execution_location:, name:)
      workspace =
        Workspace.create!(
          execution_location: execution_location,
          name: name,
        root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
          capability_tags: ["git", "shell"],
          tags: ["fixture"],
        )
      (@created_workspaces ||= []) << workspace
      workspace
    end

    def create_execution_target!(execution_location:, workspace:, name:)
      target =
        ExecutionTarget.create!(
          execution_location: execution_location,
          workspace: workspace,
          name: name,
          status: "active",
          sandboxed: true,
        )
      (@created_execution_targets ||= []) << target
      target
    end
end
