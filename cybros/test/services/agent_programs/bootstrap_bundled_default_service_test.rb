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
      setting.save!(validate: false)
    end

    expected_root = Rails.root.join("tmp/agent-workspace").to_s

    with_env("CYBROS_AGENT_WORKSPACE_ROOT" => expected_root) do
      setting = AgentPrograms::BootstrapBundledDefaultService.new.send(:ensure_runtime_setting!)
      assert_equal expected_root, setting.agent_workspace_root
    end
  end

  test "ensure_runtime_setting does not seed a runtime setting when no workspace root is configured" do
    RuntimeSetting.delete_all

    with_default_agent_workspace_root("") do
      with_env("CYBROS_AGENT_WORKSPACE_ROOT" => nil) do
        assert_no_difference -> { RuntimeSetting.count } do
          setting = AgentPrograms::BootstrapBundledDefaultService.new.send(:ensure_runtime_setting!)
          assert_nil setting
        end
      end
    end
  end

  test "bootstrap skips managed local deployment when no workspace root is configured and autolaunch is disabled" do
    RuntimeSetting.delete_all
    clear_agent_deployments!

    with_default_agent_workspace_root("") do
      with_env("CYBROS_AGENT_WORKSPACE_ROOT" => nil, "CYBROS_MANAGED_AGENT_AUTOLAUNCH" => nil) do
        with_stubbed_rails_env("development") do
          program = AgentPrograms::BootstrapBundledDefaultService.bootstrap!

          assert_predicate program, :persisted?
          assert_equal 0, program.agent_deployments.count
          assert_nil RuntimeSetting.find_by(scope_key: "instance")
        end
      end
    end
  end

  test "bootstrap raises a clear error when autolaunch is enabled without a configured workspace root" do
    RuntimeSetting.delete_all
    clear_agent_deployments!

    with_default_agent_workspace_root("") do
      with_env("CYBROS_AGENT_WORKSPACE_ROOT" => nil, "CYBROS_MANAGED_AGENT_AUTOLAUNCH" => "1") do
        with_stubbed_rails_env("development") do
          error =
            assert_raises(RuntimeSetting::InvalidAgentWorkspaceRoot) do
              AgentPrograms::BootstrapBundledDefaultService.bootstrap!
            end

          assert_equal "Agent workspace root must be configured before enabling managed agent autolaunch", error.message
        end
      end
    end
  end

  private

    def clear_agent_deployments!
      # Some tests disable transactions and can leave deployment-linked rows behind.
      AgentRPCOperationReceipt.delete_all
      AgentRPCSession.delete_all
      AgentRPCInvocation.delete_all
      RunDraft.delete_all
      ConversationRun.delete_all
      AgentDeployment.delete_all
    end

    def with_stubbed_rails_env(env_name)
      replacement = ActiveSupport::StringInquirer.new(env_name)
      original = Rails.method(:env)
      Rails.define_singleton_method(:env) { replacement }
      yield
    ensure
      Rails.define_singleton_method(:env) { original.call }
    end

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
