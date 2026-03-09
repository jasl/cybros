require "application_system_test_case"

class SystemSettingsRuntimeSettingsSystemTest < ApplicationSystemTestCase
  setup do
    RuntimeSetting.delete_all
  end

  test "owner can browse and edit the singleton runtime settings surface" do
    owner = create_user!(email: "owner-runtime-settings@example.com")

    sign_in_as!(email: owner.identity.email)
    visit system_settings_runtime_settings_path

    assert_text "Runtime Settings"
    click_link "Edit runtime settings"

    assert_current_path edit_system_settings_runtime_settings_path
    fill_in "Default worker concurrency", with: "18"
    fill_in "Queue overrides", with: <<~JSON
      {"critical":9,"default":4}
    JSON
    fill_in "Alert thresholds", with: <<~JSON
      {"provider_limit_waits":6}
    JSON

    click_button "Save runtime settings"

    assert_current_path system_settings_runtime_settings_path
    assert_text "Runtime settings updated"
    assert_text "18"
    assert_text "\"critical\": 9"
    assert_text "\"provider_limit_waits\": 6"

    runtime_setting = RuntimeSetting.find_by!(scope_key: "instance")
    assert_equal 18, runtime_setting.default_worker_concurrency
    assert_equal({ "critical" => 9, "default" => 4 }, runtime_setting.queue_overrides)
  end

  test "browser keeps invalid json-object input on the edit surface" do
    owner = create_user!(email: "owner-invalid-runtime-settings@example.com")

    sign_in_as!(email: owner.identity.email)
    visit edit_system_settings_runtime_settings_path

    fill_in "Default worker concurrency", with: "14"
    fill_in "Queue overrides", with: "[]"
    fill_in "Alert thresholds", with: <<~JSON
      {"provider_limit_waits":6}
    JSON

    click_button "Save runtime settings"

    assert_current_path edit_system_settings_runtime_settings_path
    assert_text "Queue overrides must be a JSON object"
    assert_field "Default worker concurrency", with: "14"
    assert_field "Queue overrides", with: "[]"
  end
end
