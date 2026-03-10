require "test_helper"

class LaneKvEntryTest < ActiveSupport::TestCase
  test "belongs to dag lane" do
    association = LaneKVEntry.reflect_on_association(:lane)

    assert_equal :belongs_to, association.macro
    assert_equal "DAG::Lane", association.class_name
  end

  test "requires a nonblank key and enforces uniqueness per lane" do
    lane = create_conversation!.chat_lane

    LaneKVEntry.create!(
      lane: lane,
      key: "shared.stage",
      value: { "status" => "planned" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )

    duplicate =
      LaneKVEntry.new(
        lane: lane,
        key: " shared.stage ",
        value: { "status" => "duplicate" },
      )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:key], "has already been taken"

    blank =
      LaneKVEntry.new(
        lane: lane,
        key: "   ",
        value: { "status" => "blank" },
      )

    refute_predicate blank, :valid?
    assert_includes blank.errors[:key], "can't be blank"
  end

  test "normalizes string keyed json payloads before validation" do
    lane = create_conversation!.chat_lane

    entry =
      LaneKVEntry.create!(
        lane: lane,
        key: " shared.fixture.plan ",
        value: {
          status: "planned",
          nested: [{ step_name: "draft" }],
        },
        written_by_type: "RunDraft",
        written_by_id: SecureRandom.uuid,
      )

    assert_equal "shared.fixture.plan", entry.key
    assert_equal(
      {
        "status" => "planned",
        "nested" => [{ "step_name" => "draft" }],
      },
      entry.value,
    )
  end
end
