# frozen_string_literal: true

require "test_helper"

class AgentCore::Resources::Tools::StrictJsonSchemaTest < Minitest::Test
  def test_adds_additional_properties_false_when_missing
    schema = { type: "object", properties: { "a" => { type: "string" } }, required: ["a"] }

    normalized = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema)

    assert_equal false, normalized[:additionalProperties]
    assert_equal({ "a" => { type: "string" } }, normalized[:properties])
    assert_equal ["a"], normalized[:required]
  end

  def test_fills_missing_properties_hash
    schema = { type: "object" }

    normalized = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema)

    assert_equal false, normalized[:additionalProperties]
    assert_equal({}, normalized[:properties])
  end

  def test_recursive_normalization_for_nested_objects_and_items
    schema = {
      type: "object",
      properties: {
        "nested" => {
          type: "object",
          properties: {
            "x" => { type: "string" },
          },
        },
        "list" => {
          type: "array",
          items: { type: "object" },
        },
      },
      required: ["nested", "list"],
    }

    normalized = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema)

    assert_equal false, normalized[:additionalProperties]
    assert_equal ["nested", "list"], normalized[:required]

    nested = normalized[:properties].fetch("nested")
    assert_equal false, nested[:additionalProperties]
    assert_equal({ "x" => { type: "string" } }, nested[:properties])

    list_items = normalized[:properties].fetch("list").fetch(:items)
    assert_equal false, list_items[:additionalProperties]
    assert_equal({}, list_items[:properties])
  end

  def test_does_not_mutate_input
    schema = { type: "object", properties: { "a" => { type: "object" } }, required: ["a"] }
    original = Marshal.load(Marshal.dump(schema))

    _ = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema)

    assert_equal original, schema
  end

  def test_string_key_schema_stays_string_keys
    schema = { "type" => "object", "properties" => {} }

    normalized = AgentCore::Resources::Tools::StrictJsonSchema.normalize(schema)

    assert_equal false, normalized["additionalProperties"]
    assert_equal({}, normalized["properties"])
  end
end
