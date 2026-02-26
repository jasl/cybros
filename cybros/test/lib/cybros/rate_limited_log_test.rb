require "test_helper"

class Cybros::RateLimitedLogTest < ActiveSupport::TestCase
  test "warn logs at most once per interval per key" do
    lines = []
    logger = Struct.new(:lines) { def warn(msg) lines << msg end }.new(lines)

    Cybros::RateLimitedLog.warn("k", interval_s: 10, message: "m1", logger: logger, now: 1000.0)
    Cybros::RateLimitedLog.warn("k", interval_s: 10, message: "m2", logger: logger, now: 1000.0)

    assert_equal 1, lines.length
    assert_equal "m1", lines.first
  end
end
