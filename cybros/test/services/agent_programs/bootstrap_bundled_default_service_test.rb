require "test_helper"

class AgentPrograms::BootstrapBundledDefaultServiceTest < ActiveSupport::TestCase
  test "ensure_runtime_setting adopts the managed local workspace root when a seeded default points at app root" do
    RuntimeSetting.find_or_initialize_by(scope_key: "instance").tap do |setting|
      setting.assign_attributes(
        default_worker_concurrency: RuntimeSetting::DEFAULT_WORKER_CONCURRENCY,
        queue_overrides: {},
        alert_thresholds: {},
        agent_workspace_root: Rails.root.to_s,
      )
      setting.save!
    end

    expected_root = Rails.root.join("tmp/agent-workspace").to_s

    with_env("CYBROS_AGENT_WORKSPACE_ROOT" => expected_root) do
      setting = AgentPrograms::BootstrapBundledDefaultService.new.send(:ensure_runtime_setting!)
      assert_equal expected_root, setting.agent_workspace_root
    end
  end

  private

    def with_env(values)
      original = values.to_h { |key, _value| [key, ENV[key]] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      original.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
end
