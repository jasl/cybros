require "test_helper"

class ConversationComposerDraftsTest < ActionDispatch::IntegrationTest
  test "updates composer draft without redirecting the conversation page" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    patch conversation_composer_draft_path(conversation),
          params: {
            composer_draft: {
              content: "Draft in progress",
              model_ref: "dev/mock-model",
              permission_mode: "conservative",
            },
          },
          as: :json

    assert_response :no_content

    conversation.reload
    assert_equal "Draft in progress", conversation.composer_draft["content"]
    assert_equal "dev/mock-model", conversation.composer_draft["model_ref"]
    assert_equal "conservative", conversation.composer_draft["permission_mode"]
    assert_equal "default", conversation.permission_mode
    assert_equal "openai/gpt-5.4", conversation.metadata.dig("llm", "model_ref")
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
