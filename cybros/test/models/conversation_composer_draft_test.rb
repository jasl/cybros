require "test_helper"

class ConversationComposerDraftTest < ActiveSupport::TestCase
  test "resolves composer draft values with fallbacks to conversation defaults" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    conversation.update!(
      permission_mode: "default",
      composer_draft: {
        "content" => "  finish later  ",
        "model_ref" => "dev/mock-model",
        "permission_mode" => "conservative",
        "ignored" => "drop-me",
      },
    )

    resolved = conversation.resolved_composer_draft

    assert_equal "  finish later  ", resolved.fetch("content")
    assert_equal "dev/mock-model", resolved.fetch("model_ref")
    assert_equal "conservative", resolved.fetch("permission_mode")
    assert_nil resolved["ignored"]

    conversation.update!(composer_draft: {})

    fallback = conversation.resolved_composer_draft

    assert_equal "", fallback.fetch("content")
    assert_equal "openai/gpt-5.4", fallback.fetch("model_ref")
    assert_equal "default", fallback.fetch("permission_mode")
  end

  test "ignores stale composer draft writes that arrive after a newer version" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "llm" => { "model_ref" => "openai/gpt-5.4" },
        },
      )

    conversation.update_composer_draft!(
      content: "newest draft",
      permission_mode: "conservative",
      updated_at: "2026-03-17T12:34:56.000Z",
    )
    conversation.update_composer_draft!(
      content: "older draft",
      permission_mode: "default",
      updated_at: "2026-03-17T12:34:55.000Z",
    )

    conversation.reload

    assert_equal "newest draft", conversation.composer_draft["content"]
    assert_equal "conservative", conversation.composer_draft["permission_mode"]
    assert_equal "2026-03-17T12:34:56.000000Z", conversation.composer_draft["updated_at"]
    assert_equal "newest draft", conversation.resolved_composer_draft.fetch("content")
  end
end
