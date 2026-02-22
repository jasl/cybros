# frozen_string_literal: true

require "test_helper"

class Cybros::ErrorsTest < Minitest::Test
  def test_base_error_inherits_standard_error
    assert_operator Cybros::Error, :<, StandardError
  end
end
