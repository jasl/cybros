require "application_system_test_case"

class SystemSettingsExecutionLocationsSystemTest < ApplicationSystemTestCase
  teardown do
    destroy_created_execution_inventory!
  end

  test "operator can open an execution location from the target surface and edit capacity policy" do
    owner = create_user!(email: "owner-execution-locations@example.com")
    location = create_execution_location!(name: "Primary host")
    workspace = create_workspace!(execution_location: location, name: "Primary workspace")
    target = create_execution_target!(execution_location: location, workspace: workspace, name: "Primary target")

    sign_in_as!(email: owner.identity.email)
    visit system_settings_execution_target_path(target)

    click_link "Primary host"
    assert_current_path system_settings_execution_location_path(location)
    assert_text "Execution Location"
    click_link "Edit location"

    assert_current_path edit_system_settings_execution_location_path(location)
    fill_in "Max concurrent tasks", with: "8"
    fill_in "Max queued tasks", with: "24"
    fill_in "Default timeout (seconds)", with: "1500"

    click_button "Save location"

    assert_current_path system_settings_execution_location_path(location)
    assert_text "Execution location updated"
    assert_text "8"
    assert_text "24"
    assert_text "1500"
  end

  test "browser keeps invalid numeric input on the location edit surface" do
    owner = create_user!(email: "owner-invalid-execution-location@example.com")
    location = create_execution_location!(name: "Invalid host")

    sign_in_as!(email: owner.identity.email)
    visit edit_system_settings_execution_location_path(location)

    fill_in "Max concurrent tasks", with: "abc"
    fill_in "Max queued tasks", with: "24"
    fill_in "Default timeout (seconds)", with: "0"

    click_button "Save location"

    assert_current_path edit_system_settings_execution_location_path(location)
    assert_text "Max concurrent tasks must be a positive integer"
    assert_text "Default timeout s must be a positive integer"
    assert_field "Max concurrent tasks", with: "abc"
    assert_field "Default timeout (seconds)", with: "0"
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
          cpu_limit_millicores: 2000,
          memory_limit_mb: 4096,
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
