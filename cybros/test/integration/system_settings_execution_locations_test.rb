require "test_helper"

class SystemSettingsExecutionLocationsIntegrationTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get system_settings_execution_locations_path

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_as!(role: :member)

    get system_settings_execution_locations_path

    assert_response :forbidden
  end

  test "index and show expose execution location metadata" do
    sign_in_as!(role: :owner)
    active_location = create_execution_location!(name: "Primary host", status: "active")
    inactive_location = create_execution_location!(name: "Standby host", status: "inactive")

    get system_settings_execution_locations_path

    assert_response :success
    assert_includes response.body, "Execution Locations"
    assert_includes response.body, active_location.name
    assert_includes response.body, inactive_location.name
    assert_includes response.body, "operator"
    assert_includes response.body, "development"

    get system_settings_execution_location_path(active_location)

    assert_response :success
    assert_includes response.body, active_location.platform
    assert_includes response.body, "fixture"
    assert_includes response.body, "4"
    assert_includes response.body, "16"
    assert_includes response.body, "900"
  end

  test "owner can update execution capacity fields" do
    sign_in_as!(role: :owner)
    location = create_execution_location!

    patch system_settings_execution_location_path(location), params: {
      execution_location: {
        max_concurrent_tasks: "10",
        max_queued_tasks: "40",
        default_timeout_s: "1800",
      },
    }

    assert_redirected_to system_settings_execution_location_path(location)

    location.reload
    assert_equal 10, location.max_concurrent_tasks
    assert_equal 40, location.max_queued_tasks
    assert_equal 1800, location.default_timeout_s
  end

  test "invalid numeric input rerenders edit without losing the edited values" do
    sign_in_as!(role: :admin)
    location = create_execution_location!

    patch system_settings_execution_location_path(location), params: {
      execution_location: {
        max_concurrent_tasks: "abc",
        max_queued_tasks: "40",
        default_timeout_s: "0",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Max concurrent tasks must be a positive integer"
    assert_includes response.body, "Default timeout s must be a positive integer"
    assert_includes response.body, 'value="abc"'
    assert_includes response.body, 'value="40"'
    assert_includes response.body, 'value="0"'

    location.reload
    assert_equal 4, location.max_concurrent_tasks
    assert_equal 16, location.max_queued_tasks
    assert_equal 900, location.default_timeout_s
  end

  test "execution target detail links to the execution location surface" do
    sign_in_as!(role: :owner)
    location = create_execution_location!(name: "Linked host")
    workspace = create_workspace!(execution_location: location, name: "Linked workspace")
    target = create_execution_target!(execution_location: location, workspace: workspace, name: "Linked target")

    get system_settings_execution_target_path(target)

    assert_response :success
    assert_includes response.body, system_settings_execution_location_path(location)
    assert_includes response.body, location.name
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_execution_location!(name: "Operator host", status: "active")
      ExecutionLocation.create!(
        name: name,
        kind: "host",
        platform: "macos_arm64",
        status: status,
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

    def create_workspace!(execution_location:, name:)
      Workspace.create!(
        execution_location: execution_location,
        name: name,
        root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
        workspace_type: "git",
        status: "active",
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
