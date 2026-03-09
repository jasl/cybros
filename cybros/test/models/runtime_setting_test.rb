require "test_helper"

class RuntimeSettingTest < ActiveSupport::TestCase
  test "requires positive worker concurrency" do
    settings = build_settings(default_worker_concurrency: 0)

    refute_predicate settings, :valid?
    assert settings.errors[:default_worker_concurrency].any?
  end

  test "allows only one instance-scoped settings row" do
    build_settings.save!

    duplicate = build_settings(queue_overrides: { "low" => 1 })

    refute_predicate duplicate, :valid?
    assert duplicate.errors[:base].any?
  end

  private

  def build_settings(attributes = {})
    RuntimeSetting.new(
      {
        default_worker_concurrency: 12,
        queue_overrides: { "critical" => 6 },
        alert_thresholds: { "provider_limit_waits" => 5 },
      }.merge(attributes),
    )
  end
end
