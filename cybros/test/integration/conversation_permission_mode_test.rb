require "test_helper"

class ConversationPermissionModeTest < ActionDispatch::IntegrationTest
  test "updates the conversation permission mode from the composer control" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    patch conversation_path(conversation), params: { conversation: { permission_mode: "conservative" } }

    assert_redirected_to conversation_path(conversation)
    assert_equal "conservative", conversation.reload.permission_mode

    follow_redirect!
    assert_response :success
    assert_select 'select[name="conversation[permission_mode]"] option[selected]', text: "Conservative"
  end

  test "rejects invalid permission modes and keeps the current value" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    patch conversation_path(conversation), params: { conversation: { permission_mode: "danger_zone" } }

    assert_response :unprocessable_entity
    assert_equal "default", conversation.reload.permission_mode
  end

  private

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
end
