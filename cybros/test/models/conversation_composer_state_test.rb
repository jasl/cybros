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

  test "includes active lane background processes for the composer alert" do
    conversation = create_conversation!

    lane_process =
      LaneProcess.create!(
        conversation: conversation,
        lane: conversation.chat_lane,
        status: "running",
        started_by_type: "agent",
        title: "Dev server",
        command: "bin/dev",
        port_hints: [3000],
        started_at: Time.current,
      )

    state = conversation.composer_state

    assert_equal 1, state.dig("background_processes", "active_count")
    item = state.dig("background_processes", "items").first
    assert_equal lane_process.id, item.fetch("id")
    assert_equal "Dev server", item.fetch("title")
    assert_equal "running", item.fetch("status")
    assert_equal [3000], item.fetch("port_hints")
  end
end
