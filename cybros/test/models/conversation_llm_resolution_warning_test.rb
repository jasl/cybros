require "test_helper"

class ConversationLlmResolutionWarningTest < ActiveSupport::TestCase
  test "append_user_message! records a warning on the agent placeholder when preferred model is unavailable" do
    LLMProvider.delete_all

    LLMProvider.create!(
      name: "p1",
      base_url: "http://p1.test/v1",
      api_key: "k1",
      model_allowlist: ["m2"],
      priority: 5,
      api_format: "openai",
    )

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "agent_program" => { "model_prefer" => ["m1"] },
          },
        },
      )

    result = conversation.append_user_message!(content: "hi")
    agent = result.fetch(:agent_node)

    warning = agent.metadata.fetch("llm_warning")
    assert_equal "model_preference_unavailable", warning.fetch("code")
    assert_equal ["m1"], warning.fetch("preferred_models")
    assert_equal "m2", warning.fetch("chosen_model")
    assert_equal "p1", warning.fetch("provider_name")
  end
end
