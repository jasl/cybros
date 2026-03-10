require "test_helper"

class RuntimeSettingTest < ActiveSupport::TestCase
  setup do
    RuntimeSetting.delete_all
  end

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

  test "enforces the singleton at the database layer" do
    build_settings.save!

    duplicate = build_settings

    assert_raises(ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid) do
      duplicate.save!(validate: false)
    end
  end

  test "requires an agent workspace root" do
    settings = build_settings(agent_workspace_root: "")

    refute_predicate settings, :valid?
    assert_includes settings.errors[:agent_workspace_root], "can't be blank"
  end

  test "accepts an agent workspace root" do
    settings = build_settings(agent_workspace_root: "/srv/cybros-agents")

    assert_predicate settings, :valid?
  end

  test "rejects a relative agent workspace root" do
    settings = build_settings(agent_workspace_root: "tmp/cybros-agents")

    refute_predicate settings, :valid?
    assert_includes settings.errors[:agent_workspace_root], "must be an absolute path"
  end

  test "rejects the app repository as the agent workspace root" do
    settings = build_settings(agent_workspace_root: Rails.root.to_s)

    refute_predicate settings, :valid?
    assert_includes settings.errors[:agent_workspace_root], "must point outside the Cybros app repository"
  end

  test "returns the normalized configured workspace root path" do
    settings = build_settings(agent_workspace_root: "/srv/cybros-agents/../custom-agents")

    assert_equal Pathname.new("/srv/custom-agents"), settings.agent_workspace_root_path
  end

  test "returns the default workspace root path when instance settings are absent" do
    RuntimeSetting.delete_all

    assert_equal Pathname.new(RuntimeSetting.default_agent_workspace_root).cleanpath, RuntimeSetting.instance_agent_workspace_root_path
  end

  test "raises when no configured workspace root is available" do
    RuntimeSetting.delete_all

    with_default_agent_workspace_root("") do
      error = assert_raises(RuntimeSetting::InvalidAgentWorkspaceRoot) do
        RuntimeSetting.instance_agent_workspace_root_path
      end

      assert_equal "Agent workspace root must be configured before creating custom agents", error.message
    end
  end

  private

  def build_settings(attributes = {})
    RuntimeSetting.new(
      {
        default_worker_concurrency: 12,
        queue_overrides: { "critical" => 6 },
        alert_thresholds: { "provider_limit_waits" => 5 },
        agent_workspace_root: "/tmp/cybros-agents",
      }.merge(attributes),
    )
  end
end
