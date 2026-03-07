require "test_helper"

class ConversationComposerStateTest < ActiveSupport::TestCase
  test "does not report the first coalescing-window turn as a queued next turn" do
    conversation =
      create_conversation!(
        metadata: {
          "agent" => { "agent_profile" => "coding" },
        },
      )

    conversation.append_user_message!(content: "first request")

    state = conversation.composer_state

    assert_equal false, state.fetch("running")
    assert_equal 0, state.dig("queue", "queued_count")
    assert_equal "", state.dig("candidate_preview", "content").to_s
  end
end
