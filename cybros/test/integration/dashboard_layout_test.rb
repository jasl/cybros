require "test_helper"

class DashboardLayoutTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "dashboard renders with agent layout" do
    user = create_user!
    sign_in!(user)

    get dashboard_path
    assert_response :success

    assert_includes response.body, 'data-layout="agent"'
    refute_includes response.body, 'data-layout="settings"'
  end
end
