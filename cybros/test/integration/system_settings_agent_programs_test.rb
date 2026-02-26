require "test_helper"

class SystemSettingsAgentProgramsTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "index supports search" do
    sign_in_owner!
    AgentProgram.create!(name: "Alpha", profile_source: "bundled:coding", local_path: "agents/alpha")
    AgentProgram.create!(name: "Beta", profile_source: "bundled:coding", local_path: "agents/beta")

    get system_settings_agent_programs_path, params: { q: "alp" }
    assert_response :success
    assert_includes response.body, "Alpha"
    assert_not_includes response.body, "Beta"
  end

  test "create validates name and profile" do
    sign_in_owner!

    get new_system_settings_agent_program_path
    assert_response :success

    post system_settings_agent_programs_path, params: { agent_program: { name: "", profile_source: "" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "Name and profile are required"
  end
end
