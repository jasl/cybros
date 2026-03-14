require "test_helper"

class ConversationLlmResolutionWarningTest < ActiveSupport::TestCase
  test "append_user_message! hard-errors when preferred model is unavailable" do
    LLMProviderCredential.delete_all

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "model_prefer" => ["does-not-exist"],
          },
        },
      )

    error = assert_raises(AgentCore::ValidationError) { conversation.append_user_message!(content: "hi") }
    assert_equal "cybros.llm.model_preference_unavailable", error.code
  end
end
