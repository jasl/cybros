require "application_system_test_case"
require "fileutils"

class SystemSettingsAgentProgramsSystemTest < ApplicationSystemTestCase
  teardown do
    FileUtils.rm_rf(@agent_workspace_root) if @agent_workspace_root.present?
  end

  test "operator can fork the bundled default agent from the settings UI" do
    owner = create_user!(email: "owner-agent-programs@example.com")
    @agent_workspace_root = Dir.mktmpdir("cybros-agent-workspace-")
    RuntimeSetting.delete_all
    RuntimeSetting.create!(
      default_worker_concurrency: 12,
      queue_overrides: {},
      alert_thresholds: {},
      agent_workspace_root: @agent_workspace_root,
    )
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    sign_in_as!(email: owner.identity.email)
    visit system_settings_agent_program_path(bundled)

    assert_text "Copy as custom agent"
    fill_in "Fork name", with: "My forked assistant"
    click_button "Copy as custom agent"

    assert_selector "h2", text: "My forked assistant"
    forked = AgentProgram.find_by!(name: "My forked assistant")

    assert_current_path system_settings_agent_program_path(forked)
    assert_text forked.local_path
    assert_equal bundled.id, forked.forked_from_agent_program_id
    assert_equal true, forked.absolute_local_path.join(".git").directory?
  end
end
