require "test_helper"

class SystemSettingsWorkspacesIntegrationTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get system_settings_workspaces_path

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_as!(role: :member)

    get system_settings_workspaces_path

    assert_response :forbidden
  end

  test "index and show expose workspace location context and capability tags" do
    sign_in_as!(role: :owner)
    location = create_execution_location!(name: "Primary host")
    workspace = create_workspace!(execution_location: location, name: "Primary workspace", status: "active")
    inactive_workspace = create_workspace!(execution_location: location, name: "Standby workspace", status: "inactive")

    get system_settings_workspaces_path

    assert_response :success
    assert_includes response.body, "Workspaces"
    assert_includes response.body, workspace.name
    assert_includes response.body, inactive_workspace.name
    assert_includes response.body, location.name
    assert_includes response.body, "git"
    assert_includes response.body, "shell"

    get system_settings_workspace_path(workspace)

    assert_response :success
    assert_includes response.body, workspace.root_path
    assert_includes response.body, "active"
    assert_includes response.body, "git"
    assert_includes response.body, "operator"
  end

  test "owner can update workspace operator fields" do
    sign_in_as!(role: :owner)
    location = create_execution_location!
    workspace = create_workspace!(execution_location: location)

    patch system_settings_workspace_path(workspace), params: {
      workspace: {
        status: "inactive",
        capability_tags_text: "git, ruby, shell",
        tags_text: "sensitive, fixture",
      },
    }

    assert_redirected_to system_settings_workspace_path(workspace)

    workspace.reload
    assert_equal "inactive", workspace.status
    assert_equal %w[git ruby shell], workspace.capability_tags
    assert_equal %w[sensitive fixture], workspace.tags
  end

  test "invalid workspace status rerenders edit with the edited values intact" do
    sign_in_as!(role: :admin)
    location = create_execution_location!
    workspace = create_workspace!(execution_location: location)

    patch system_settings_workspace_path(workspace), params: {
      workspace: {
        status: "paused",
        capability_tags_text: "git, ops",
        tags_text: "protected",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Status is not included in the list"
    assert_includes response.body, "git, ops"
    assert_includes response.body, "protected"

    workspace.reload
    assert_equal "active", workspace.status
    assert_equal %w[git shell], workspace.capability_tags
  end

  test "execution target and location surfaces link to the workspace page" do
    sign_in_as!(role: :owner)
    location = create_execution_location!(name: "Linked host")
    workspace = create_workspace!(execution_location: location, name: "Linked workspace")
    target = create_execution_target!(execution_location: location, workspace: workspace, name: "Linked target")

    get system_settings_execution_target_path(target)

    assert_response :success
    assert_includes response.body, system_settings_workspace_path(workspace)
    assert_includes response.body, workspace.root_path

    get system_settings_execution_location_path(location)

    assert_response :success
    assert_includes response.body, system_settings_workspace_path(workspace)
    assert_includes response.body, workspace.name
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_execution_location!(name: "Operator host")
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
    end

    def create_workspace!(execution_location:, name: "Operator workspace", status: "active")
      Workspace.create!(
        execution_location: execution_location,
        name: name,
        root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: status,
        capability_tags: ["git", "shell"],
        tags: ["fixture"],
      )
    end

    def create_execution_target!(execution_location:, workspace:, name:)
      ExecutionTarget.create!(
        execution_location: execution_location,
        workspace: workspace,
        name: name,
        status: "active",
        sandboxed: true,
      )
    end
end
