require "test_helper"

class ExecutionLocationTest < ActiveSupport::TestCase
  test "requires explicit execution quota inputs" do
    location =
      build_location(
        max_concurrent_tasks: nil,
        max_queued_tasks: nil,
        default_timeout_s: nil,
      )

    refute_predicate location, :valid?
    assert_includes location.errors[:max_concurrent_tasks], "can't be blank"
    assert_includes location.errors[:max_queued_tasks], "can't be blank"
    assert_includes location.errors[:default_timeout_s], "can't be blank"
  end

  test "requires discovery policy inputs" do
    location = build_location(trust_group: nil, environment: nil)

    refute_predicate location, :valid?
    assert_includes location.errors[:trust_group], "can't be blank"
    assert_includes location.errors[:environment], "can't be blank"
  end

  private

  def build_location(attributes = {})
    ExecutionLocation.new(
      {
        name: "Primary workstation",
        kind: "host",
        platform: "macos_arm64",
        status: "active",
        trust_group: "operator",
        environment: "development",
        tags: %w[local coding],
        max_concurrent_tasks: 4,
        max_queued_tasks: 16,
        default_timeout_s: 900,
        cpu_limit_millicores: 2_000,
        memory_limit_mb: 4_096,
      }.merge(attributes),
    )
  end
end
