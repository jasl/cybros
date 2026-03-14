require "test_helper"

class ConversationLlmResolutionWarningTest < ActiveSupport::TestCase
  test "append_user_message! falls back to the site default when preferred model is unavailable" do
    LLMProviderCredential.delete_all
    ensure_llm_provider!(provider_key: "dev", credential_type: "api_key", api_key: "sk-dev")
    Account.instance.update_llm_default_model_ref!("dev/mock-model")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "model_prefer" => ["does-not-exist"],
          },
        },
      )

    result = conversation.append_user_message!(content: "hi")

    assert_kind_of DAG::Node, result.fetch(:agent_node)
    assert_equal "dev/mock-model", conversation.reload.metadata.dig("llm", "model_ref")
  end
end
