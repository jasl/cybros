require "test_helper"

class ModelPickerCredentialGatingTest < ActionDispatch::IntegrationTest
  def sign_in!(email:)
    identity =
      Identity.create!(
        email: email,
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )
    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: email, password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "model picker hides openrouter models when api_key is missing" do
    LLMProviderCredential.delete_all
    user = sign_in!(email: "a@example.com")
    conversation = Conversation.create!(user: user, title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "dev/mock-model"
    refute_includes response.body, "openrouter/openai-gpt-5.4-pro"

    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-test")

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "openrouter/openai-gpt-5.4-pro"
  end
end
