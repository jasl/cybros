require "test_helper"

class SystemSettingsExecutionTargetsIntegrationTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    target = create_execution_target!

    get edit_system_settings_execution_target_path(target)

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    target = create_execution_target!
    sign_in_as!(role: :member)

    get edit_system_settings_execution_target_path(target)

    assert_response :forbidden
  end

  test "show exposes inherited versus overridden execution capacity policy" do
    sign_in_as!(role: :owner)
    target =
      create_execution_target!(
        max_concurrent_tasks_override: 2,
        max_queued_tasks_override: nil,
        default_timeout_s_override: 600,
      )

    get system_settings_execution_target_path(target)

    assert_response :success
    assert_includes response.body, "Execution capacity policy"
    assert_includes response.body, "Execution capacity overrides"
    refute_includes response.body, "Quota overrides"
    assert_includes response.body, "Max concurrent tasks"
    assert_includes response.body, "2"
    assert_includes response.body, "Override"
    assert_includes response.body, "Inherited"
    assert_includes response.body, "16"
    assert_includes response.body, "600"
  end

  test "owner can update target override fields" do
    sign_in_as!(role: :owner)
    target = create_execution_target!

    patch system_settings_execution_target_path(target), params: {
      execution_target: {
        max_concurrent_tasks_override: "3",
        max_queued_tasks_override: "12",
        default_timeout_s_override: "750",
      },
    }

    assert_redirected_to system_settings_execution_target_path(target)

    target.reload
    assert_equal 3, target.max_concurrent_tasks_override
    assert_equal 12, target.max_queued_tasks_override
    assert_equal 750, target.default_timeout_s_override
  end

  test "blank submissions clear target overrides back to inherited policy" do
    sign_in_as!(role: :owner)
    target =
      create_execution_target!(
        max_concurrent_tasks_override: 7,
        max_queued_tasks_override: 33,
        default_timeout_s_override: 1111,
      )

    patch system_settings_execution_target_path(target), params: {
      execution_target: {
        max_concurrent_tasks_override: "",
        max_queued_tasks_override: "",
        default_timeout_s_override: "",
      },
    }

    assert_redirected_to system_settings_execution_target_path(target)
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Inherited from location"
    assert_includes response.body, "Inherited"
    refute_includes response.body, "1111"

    target.reload
    assert_nil target.max_concurrent_tasks_override
    assert_nil target.max_queued_tasks_override
    assert_nil target.default_timeout_s_override
  end

  test "invalid numeric input rerenders edit without losing the edited values" do
    sign_in_as!(role: :admin)
    target = create_execution_target!

    patch system_settings_execution_target_path(target), params: {
      execution_target: {
        max_concurrent_tasks_override: "abc",
        max_queued_tasks_override: "0",
        default_timeout_s_override: "750",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Max concurrent tasks override must be a positive integer"
    assert_includes response.body, "Max queued tasks override must be a positive integer"
    assert_includes response.body, 'value="abc"'
    assert_includes response.body, 'value="0"'
    assert_includes response.body, 'value="750"'

    target.reload
    assert_nil target.max_concurrent_tasks_override
    assert_nil target.max_queued_tasks_override
    assert_nil target.default_timeout_s_override
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_execution_target!(max_concurrent_tasks_override: nil, max_queued_tasks_override: nil, default_timeout_s_override: nil)
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

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: "Editable target",
        status: "active",
        sandboxed: true,
        max_concurrent_tasks_override: max_concurrent_tasks_override,
        max_queued_tasks_override: max_queued_tasks_override,
        default_timeout_s_override: default_timeout_s_override,
      )
    end
end
