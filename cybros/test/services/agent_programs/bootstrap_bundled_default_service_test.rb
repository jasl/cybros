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

  test "clear_agent_deployments! deletes cyclic agent rpc session and invocation rows left by prior tests" do
    program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    deployment = program.agent_deployments.order(:created_at).last
    assert deployment, "expected bundled default bootstrap to provide a deployment"
    conversation = create_conversation!(agent_program: program)
    invocation =
      AgentRPCInvocation.create!(
        agent_deployment: deployment,
        conversation: conversation,
        binding_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at,
        invocation_id: SecureRandom.uuid,
        method: "before_finalize_output",
        request_payload_hash: SecureRandom.hex(32),
        result_snapshot: {},
        error_snapshot: {},
        scope_type: "conversation_run",
        scope_id: SecureRandom.uuid,
        status: "succeeded",
      )
    session =
      AgentRPCSession.create!(
        agent_deployment: deployment,
        agent_program: program,
        agent_rpc_invocation: invocation,
        conversation: conversation,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at,
        session_token_digest: SecureRandom.hex(32),
        allowed_methods: ["tool_surface.manifest"],
        expires_at: 5.minutes.from_now.change(usec: 0),
        scope_type: invocation.scope_type,
        scope_id: invocation.scope_id,
        status: "closed",
      )
    invocation.update!(last_session: session)

    assert_nothing_raised { clear_agent_deployments! }
    assert_equal 0, AgentRPCOperationReceipt.count
    assert_equal 0, AgentRPCSession.count
    assert_equal 0, AgentRPCInvocation.count
    assert_equal 0, AgentDeployment.count
  end

  private

    def clear_agent_deployments!
      # Some tests disable transactions and can leave deployment-linked rows behind.
      AgentRPCOperationReceipt.delete_all
      AgentRPCInvocation.update_all(last_session_id: nil)
      AgentRPCSession.update_all(agent_rpc_invocation_id: nil)
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
