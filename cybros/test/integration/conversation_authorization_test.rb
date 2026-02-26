require "test_helper"

class ConversationAuthorizationTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "user cannot access another user's conversation (show + messages + stop + retry)" do
    user_a = create_user!
    user_b = create_user!
    convo_b = create_conversation!(user: user_b, title: "B")

    sign_in!(user_a)

    get conversation_path(convo_b)
    assert_response :not_found

    get conversation_messages_path(convo_b), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :not_found

    post conversation_messages_path(convo_b), params: { content: "hi" }
    assert_response :not_found

    post stop_conversation_path(convo_b), params: { node_id: "0194f3c0-0000-7000-8000-00000000ffff" }
    assert_response :not_found

    post retry_conversation_path(convo_b), params: { node_id: "0194f3c0-0000-7000-8000-00000000ffff" }
    assert_response :not_found
  end

  test "index only shows current user's conversations" do
    user_a = create_user!
    user_b = create_user!

    create_conversation!(user: user_a, title: "A1")
    create_conversation!(user: user_b, title: "B1")

    sign_in!(user_a)

    get conversations_path
    assert_response :success
    assert_includes response.body, "A1"
    refute_includes response.body, "B1"
  end
end
