# frozen_string_literal: true

require "test_helper"

class DAG::ErrorsTest < Minitest::Test
  def test_error_hierarchy
    assert_operator DAG::Error, :<, StandardError
    assert_operator DAG::ValidationError, :<, DAG::Error
    assert_operator DAG::SafetyLimits::Exceeded, :<, DAG::Error
    assert_operator DAG::TopologicalSort::CycleError, :<, DAG::Error
  end
end
