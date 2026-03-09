require "application_system_test_case"

class SystemSettingsExecutionTargetsSystemTest < ApplicationSystemTestCase
  teardown do
    destroy_created_execution_inventory!
  end

  test "operator can edit target execution-capacity overrides from the browser" do
    owner = create_user!(email: "owner-execution-targets@example.com")
    target = create_execution_target!

    sign_in_as!(email: owner.identity.email)
    visit system_settings_execution_target_path(target)

    assert_text "Execution capacity policy"
    click_link "Edit target"

    assert_current_path edit_system_settings_execution_target_path(target)
    fill_in "Max concurrent tasks override", with: "5"
    fill_in "Max queued tasks override", with: "20"
    fill_in "Default timeout override (seconds)", with: "1200"

    click_button "Save target"

    assert_current_path system_settings_execution_target_path(target)
    assert_text "Target overrides updated"
    assert_text "5"
    assert_text "20"
    assert_text "1200"
    assert_text "Override"
  end

  test "browser keeps invalid override input on the edit surface" do
    owner = create_user!(email: "owner-invalid-execution-targets@example.com")
    target = create_execution_target!

    sign_in_as!(email: owner.identity.email)
    visit edit_system_settings_execution_target_path(target)

    fill_in "Max concurrent tasks override", with: "abc"
    fill_in "Max queued tasks override", with: "0"
    fill_in "Default timeout override (seconds)", with: "1200"

    click_button "Save target"

    assert_current_path edit_system_settings_execution_target_path(target)
    assert_text "Max concurrent tasks override must be a positive integer"
    assert_text "Max queued tasks override must be a positive integer"
    assert_field "Max concurrent tasks override", with: "abc"
    assert_field "Max queued tasks override", with: "0"
  end

  private

    def destroy_created_execution_inventory!
      Array(@created_execution_targets).reverse_each(&:destroy!)
      Array(@created_workspaces).reverse_each(&:destroy!)
      Array(@created_execution_locations).reverse_each(&:destroy!)
    end

    def create_execution_target!
      location =
        ExecutionLocation.create!(
          name: "Target host",
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
      (@created_execution_locations ||= []) << location
      workspace =
        Workspace.create!(
          execution_location: location,
          name: "Target workspace",
          root_path: "/tmp/target-workspace-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git", "shell"],
          tags: ["fixture"],
        )
      (@created_workspaces ||= []) << workspace

      target =
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: "Editable target",
          status: "active",
          sandboxed: true,
        )
      (@created_execution_targets ||= []) << target
      target
    end
end
