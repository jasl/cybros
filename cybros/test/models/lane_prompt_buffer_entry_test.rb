require "test_helper"

class LanePromptBufferEntryTest < ActiveSupport::TestCase
  test "belongs to dag lane" do
    association = LanePromptBufferEntry.reflect_on_association(:lane)

    assert_equal :belongs_to, association.macro
    assert_equal "DAG::Lane", association.class_name
  end

  test "requires buffer name seq and content and stores estimated tokens" do
    lane = create_conversation!.chat_lane

    entry =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "summaries",
        seq: 1,
        kind: "summary",
        content: "Summarized lane state",
        priority: 5,
        estimated_tokens: 42,
        metadata: { "source" => "fixture" },
      )

    assert_equal 42, entry.estimated_tokens

    invalid =
      LanePromptBufferEntry.new(
        lane: lane,
        buffer_name: "   ",
        seq: 0,
        kind: "summary",
        content: "   ",
        estimated_tokens: 1,
      )

    refute_predicate invalid, :valid?
    assert_includes invalid.errors[:buffer_name], "can't be blank"
    assert_includes invalid.errors[:seq], "must be greater than 0"
    assert_includes invalid.errors[:content], "can't be blank"
  end

  test "orders prompt buffer entries by seq" do
    lane = create_conversation!.chat_lane

    LanePromptBufferEntry.create!(
      lane: lane,
      buffer_name: "working_notes",
      seq: 20,
      kind: "note",
      content: "Second note",
      estimated_tokens: 10,
    )
    LanePromptBufferEntry.create!(
      lane: lane,
      buffer_name: "working_notes",
      seq: 10,
      kind: "note",
      content: "First note",
      estimated_tokens: 8,
    )

    assert_equal [10, 20], LanePromptBufferEntry.where(lane: lane, buffer_name: "working_notes").ordered.pluck(:seq)
  end
end
