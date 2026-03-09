require "test_helper"

class SessionFormTest < ActionDispatch::IntegrationTest
  test "sign in form submits outside turbo" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    get new_session_path

    assert_response :success
    assert_includes response.body, 'data-turbo="false"'
  end
end
