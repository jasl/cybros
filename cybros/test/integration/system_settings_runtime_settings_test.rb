require "test_helper"

class SystemSettingsRuntimeSettingsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    RuntimeSetting.delete_all
  end

  test "requires authentication" do
    get system_settings_runtime_settings_path

    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_as!(role: :member)

    get system_settings_runtime_settings_path

    assert_response :forbidden
  end

  test "owner can create singleton runtime settings from the edit surface" do
    sign_in_as!(role: :owner)

    assert_difference -> { RuntimeSetting.count }, +1 do
      patch system_settings_runtime_settings_path, params: {
        runtime_setting: {
          default_worker_concurrency: "16",
          agent_workspace_root: "/srv/cybros-agents",
          queue_overrides_json: <<~JSON,
            {"critical":8,"default":4}
          JSON
          alert_thresholds_json: <<~JSON,
            {"provider_limit_waits":5,"execution_capacity_waits":3}
          JSON
        },
      }
    end

    assert_redirected_to system_settings_runtime_settings_path

    runtime_setting = RuntimeSetting.find_by!(scope_key: "instance")
    assert_equal 16, runtime_setting.default_worker_concurrency
    assert_equal "/srv/cybros-agents", runtime_setting.agent_workspace_root
    assert_equal({ "critical" => 8, "default" => 4 }, runtime_setting.queue_overrides)
    assert_equal({ "provider_limit_waits" => 5, "execution_capacity_waits" => 3 }, runtime_setting.alert_thresholds)
  end

  test "admin updates the existing singleton row instead of creating another" do
    sign_in_as!(role: :admin)
    runtime_setting =
      RuntimeSetting.create!(
        default_worker_concurrency: 12,
        agent_workspace_root: "/srv/cybros-agents",
        queue_overrides: { "critical" => 6 },
        alert_thresholds: { "provider_limit_waits" => 5 },
      )

    assert_no_difference -> { RuntimeSetting.count } do
      patch system_settings_runtime_settings_path, params: {
        runtime_setting: {
          default_worker_concurrency: "24",
          agent_workspace_root: "/srv/custom-agents",
          queue_overrides_json: <<~JSON,
            {"critical":12}
          JSON
          alert_thresholds_json: <<~JSON,
            {"provider_limit_waits":9}
          JSON
        },
      }
    end

    assert_redirected_to system_settings_runtime_settings_path

    runtime_setting.reload
    assert_equal 24, runtime_setting.default_worker_concurrency
    assert_equal "/srv/custom-agents", runtime_setting.agent_workspace_root
    assert_equal({ "critical" => 12 }, runtime_setting.queue_overrides)
    assert_equal({ "provider_limit_waits" => 9 }, runtime_setting.alert_thresholds)
  end

  test "invalid object input rerenders edit with inline validation" do
    sign_in_as!(role: :owner)

    patch system_settings_runtime_settings_path, params: {
      runtime_setting: {
        default_worker_concurrency: "10",
        agent_workspace_root: "",
        queue_overrides_json: "[]",
        alert_thresholds_json: "{\"provider_limit_waits\":5}",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Agent workspace root can&#39;t be blank"
    assert_includes response.body, "Queue overrides must be a JSON object"
    assert_includes response.body, 'value="10"'
    assert_includes response.body, "[]"
    assert_nil RuntimeSetting.find_by(scope_key: "instance")
  end

  test "invalid default worker concurrency keeps the original input on the edit surface" do
    sign_in_as!(role: :owner)

    patch system_settings_runtime_settings_path, params: {
      runtime_setting: {
        default_worker_concurrency: "abc",
        agent_workspace_root: "/srv/cybros-agents",
        queue_overrides_json: "{\"critical\":8}",
        alert_thresholds_json: "{\"provider_limit_waits\":5}",
      },
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Default worker concurrency must be a positive integer"
    assert_includes response.body, 'value="abc"'
    assert_nil RuntimeSetting.find_by(scope_key: "instance")
  end

  private

    def sign_in_as!(role:)
      user = create_user!(role: role)

      post session_path, params: { email: user.identity.email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?

      user
    end
end
