# frozen_string_literal: true

require "test_helper"

class DAG::ErrorsTest < Minitest::Test
  def test_error_hierarchy
    assert_operator DAG::Error, :<, StandardError
    assert_operator DAG::ValidationError, :<, DAG::Error
    assert_operator DAG::SafetyLimits::Exceeded, :<, DAG::Error
    assert_operator DAG::TopologicalSort::CycleError, :<, DAG::Error
  end

  def test_validation_error_raise_requires_code
    assert_raises(ArgumentError) { DAG::ValidationError.raise!("bad input") }
  end

  def test_validation_error_raise_sets_code_and_details
    error =
      assert_raises(DAG::ValidationError) do
        DAG::ValidationError.raise!("bad input", code: "dag.example.bad_input", details: { field: "name" })
      end

    assert_equal "bad input", error.message
    assert_equal "dag.example.bad_input", error.code
    assert_equal({ field: "name" }, error.details)
  end
end
