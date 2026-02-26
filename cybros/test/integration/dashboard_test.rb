require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "dashboard renders status cards and recent conversations" do
    user = sign_in_owner!
    create_conversation!(user: user, title: "Hello")

    get dashboard_path
    assert_response :success
    assert_includes response.body, 'data-layout="agent"'
    assert_includes response.body, 'data-testid="dashboard-page"'
    assert_includes response.body, "Dashboard"
    assert_includes response.body, "Recent conversations"
    refute_includes response.body, "Dashboard content will be filled in next."
  end

  test "dashboard only shows current user's conversations" do
    user_a = sign_in_owner!
    create_conversation!(user: user_a, title: "My Chat")

    user_b = create_user!
    create_conversation!(user: user_b, title: "Other Chat")

    get dashboard_path
    assert_response :success
    assert_includes response.body, "My Chat"
    refute_includes response.body, "Other Chat"
  end
end
