require "test_helper"

class ConversationPaginationTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "conversations index supports before cursor pagination and rejects invalid cursor" do
    user = create_user!
    sign_in!(user)

    old = create_conversation!(user: user, title: "Old")
    mid = create_conversation!(user: user, title: "Mid")
    new = create_conversation!(user: user, title: "New")

    get conversations_path
    assert_response :success
    assert_includes response.body, "<td>New</td>"
    assert_includes response.body, "<td>Mid</td>"
    assert_includes response.body, "<td>Old</td>"

    get conversations_path(before: mid.id)
    assert_response :success
    assert_includes response.body, "<td>Old</td>"
    refute_includes response.body, "<td>Mid</td>"
    refute_includes response.body, "<td>New</td>"

    get conversations_path(before: "not-a-uuid")
    assert_response :unprocessable_entity
  end

  test "messages endpoint pages older messages using before cursor (turbo stream prepend)" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")

    3.times do |i|
      post conversation_messages_path(conversation), params: { content: "m#{i + 1}" }
      assert_redirected_to conversation_path(conversation)
    end

    lane = conversation.reload.dag_graph.main_lane
    page = lane.message_page(limit: 4, mode: :preview)
    before_cursor = page.fetch("before_message_id").to_s
    assert before_cursor.present?

    get conversation_messages_path(conversation),
        params: { before: before_cursor },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    # If there are older messages, we expect a prepend stream update.
    assert_response :success
    assert_includes response.body, 'turbo-stream action="prepend"'
  end
end
