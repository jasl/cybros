require "test_helper"

class AgentProgramsTest < ActionDispatch::IntegrationTest
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

    identity
  end

  test "requires authentication" do
    get agent_programs_path
    assert_redirected_to new_session_path
  end

  test "index lists agent programs" do
    sign_in_owner!

    program = AgentProgram.create!(name: "Default assistant", description: "A helpful agent", profile_source: "default-assistant")

    get agent_programs_path
    assert_response :success
    assert_includes response.body, program.name
  end

  test "create from bundled profile copies files into storage and persists local_path" do
    sign_in_owner!

    assert_difference -> { AgentProgram.count }, +1 do
      post agent_programs_path, params: {
        agent_program: {
          name: "Default assistant",
          profile_source: "default-assistant",
        },
      }
    end

    program = AgentProgram.order(:created_at).last
    assert_redirected_to agent_program_path(program)

    path = program.local_path.to_s
    assert path.present?

    abs = Rails.root.join(path)
    assert abs.directory?

    assert (abs / "agent.yml").file?
    assert (abs / "AGENT.md").file?
    assert (abs / "SOUL.md").file?
    assert (abs / "USER.md").file?
    assert (abs / "prompts" / "system.md.liquid").file?
  end
end
