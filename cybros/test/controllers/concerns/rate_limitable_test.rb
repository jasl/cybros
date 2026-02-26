require "test_helper"

class RateLimitableTest < ActionDispatch::IntegrationTest
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "message create is throttled after limit" do
    user = create_user!
    post session_path, params: { email: user.identity.email, password: "Passw0rd" }

    conversation = create_conversation!(user: user, title: "Rate limit test")

    20.times do |i|
      post conversation_messages_path(conversation), params: { content: "msg #{i}" }
      assert_response :redirect
    end

    post conversation_messages_path(conversation), params: { content: "over limit" }
    assert_response :too_many_requests
  end

  test "stop endpoint is throttled after limit" do
    user = create_user!
    post session_path, params: { email: user.identity.email, password: "Passw0rd" }

    conversation = create_conversation!(user: user, title: "Rate limit test")

    10.times do
      post stop_conversation_path(conversation), params: { node_id: "0194f3c0-0000-7000-8000-00000000ffff" }
    end

    post stop_conversation_path(conversation), params: { node_id: "0194f3c0-0000-7000-8000-00000000ffff" }
    assert_response :too_many_requests
  end
end
