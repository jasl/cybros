require "test_helper"

class AgentCore::Resources::Tools::JsonSchemaLiteValidatorTest < Minitest::Test
  def test_missing_required
    schema = {
      "type" => "object",
      "required" => ["text"],
      "properties" => {
        "text" => { "type" => "string" },
      },
    }

    errors = AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(arguments: {}, schema: schema, max_depth: 2)
    assert_equal 1, errors.length
    assert_equal "missing_required", errors.first.fetch("code")
    assert_equal ["text"], errors.first.fetch("path")
  end

  def test_unknown_key_only_when_additional_properties_false_and_properties_present
    schema = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "bar" => { "type" => "string" },
      },
    }

    errors = AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(arguments: { "foo" => 1 }, schema: schema, max_depth: 2)
    assert_equal 1, errors.length
    assert_equal "unknown_key", errors.first.fetch("code")
    assert_equal ["foo"], errors.first.fetch("path")

    schema_allow = schema.merge("additionalProperties" => true)
    errors_allow = AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(arguments: { "foo" => 1 }, schema: schema_allow, max_depth: 2)
    assert_equal [], errors_allow

    schema_no_props = { "type" => "object", "additionalProperties" => false, "properties" => {} }
    errors_no_props = AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(arguments: { "foo" => 1 }, schema: schema_no_props, max_depth: 2)
    assert_equal [], errors_no_props
  end

  def test_type_mismatch
    schema = {
      "type" => "object",
      "properties" => {
        "limit" => { "type" => "integer" },
      },
    }

    errors =
      AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(
        arguments: { "limit" => "10" },
        schema: schema,
        max_depth: 2,
      )

    assert_equal 1, errors.length
    assert_equal "type_mismatch", errors.first.fetch("code")
    assert_equal ["limit"], errors.first.fetch("path")
  end

  def test_depth_limit_skips_nested_validation_at_zero
    schema = {
      "type" => "object",
      "required" => ["opts"],
      "properties" => {
        "opts" => {
          "type" => "object",
          "required" => ["limit"],
          "properties" => { "limit" => { "type" => "integer" } },
        },
      },
    }

    args = { "opts" => {} }

    errors_depth0 =
      AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(
        arguments: args,
        schema: schema,
        max_depth: 0,
      )
    assert_equal [], errors_depth0

    errors_depth1 =
      AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(
        arguments: args,
        schema: schema,
        max_depth: 1,
      )
    assert_equal 1, errors_depth1.length
    assert_equal "missing_required", errors_depth1.first.fetch("code")
    assert_equal ["opts", "limit"], errors_depth1.first.fetch("path")
  end

  def test_summarize_truncates
    errors = 30.times.map { |i| { "code" => "missing_required", "path" => ["k#{i}"], "expected" => "present" } }
    summary = AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors, max_bytes: 50)
    assert_operator summary.bytesize, :<=, 50
    assert_includes summary, "missing_required"
  end
end
