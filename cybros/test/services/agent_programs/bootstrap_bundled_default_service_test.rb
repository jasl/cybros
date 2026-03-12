require "test_helper"

class AgentPrograms::BootstrapBundledDefaultServiceTest < ActiveSupport::TestCase
  FakeManagedLocalProgram = Struct.new(:selectable_sequence, :reloads) do
    def initialize(selectable_sequence)
      super(selectable_sequence.dup, 0)
    end

    def reload
      self.reloads += 1
      self
    end

    def selectable_for_conversation?
      selectable_sequence.length > 1 ? selectable_sequence.shift : selectable_sequence.first
    end
  end

  FakeManagedLocalDeployment = Struct.new(:status_sequence, :health_sequence, :agent_program, :reloads, :status, :health_status) do
    def initialize(status_sequence:, health_sequence:, agent_program:)
      super(status_sequence.dup, health_sequence.dup, agent_program, 0, nil, nil)
    end

    def reload
      self.reloads += 1
      self.status = status_sequence.length > 1 ? status_sequence.shift : status_sequence.first
      self.health_status = health_sequence.length > 1 ? health_sequence.shift : health_sequence.first
      self
    end

    def id
      "fake-managed-local-deployment"
    end
  end

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

  test "wait_for_managed_local_activation waits until the program is selectable for conversations" do
    program = FakeManagedLocalProgram.new([false, true])
    deployment =
      FakeManagedLocalDeployment.new(
        status_sequence: ["active", "active"],
        health_sequence: ["healthy", "healthy"],
        agent_program: program,
      )
    service = AgentPrograms::BootstrapBundledDefaultService.new

    result =
      service.wait_for_managed_local_activation!(
        deployment: deployment,
        timeout: 1.second,
        agent_program: program,
      )

    assert_same deployment, result
    assert_operator deployment.reloads, :>=, 2
    assert_operator program.reloads, :>=, 2
  end

  test "ensure_managed_local_deployment reconciles stale contract fingerprints on reused managed deployments" do
    program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    clear_agent_deployments!
    runtime_config_path = Rails.root.join("tmp", "managed-local-runtime-config.json").to_s
    deployment =
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: AgentDeployment.local_endpoint_url(host: "127.0.0.1", port: 4319, rpc_path: "/rpc"),
        deployment_bearer_secret_ref: "secret://stale",
        contract_fingerprint: "contract:sha256:stale",
        deployment_fingerprint: AgentPrograms::BootstrapBundledDefaultService::DEFAULT_DEPLOYMENT_FINGERPRINT,
        status: "active",
        health_status: "healthy",
        protocol_version: AgentDeployments::SUPPORTED_PROTOCOL_VERSION,
        supported_methods: ["initialize"],
        transport_config: {
          "host" => "127.0.0.1",
          "bind_host" => "127.0.0.1",
          "port" => 4319,
          "rpc_path" => "/rpc",
          "runtime_config_path" => runtime_config_path,
        },
        manifest_snapshot: { "stale" => true },
        schema_snapshot: { "stale" => true },
        capability_snapshot: { "stale" => true },
        inspection_details: { "supervisor" => { "error_message" => "stale" } },
      )

    reconciled =
      AgentPrograms::BootstrapBundledDefaultService.new.ensure_managed_local_deployment!(
        program: program,
        default_fingerprint: AgentPrograms::BootstrapBundledDefaultService::DEFAULT_DEPLOYMENT_FINGERPRINT,
        default_bearer_secret_ref: AgentPrograms::BootstrapBundledDefaultService::DEFAULT_DEPLOYMENT_BEARER,
      )

    assert_equal deployment.id, reconciled.id
    assert_equal program.published_contract_fingerprint, reconciled.contract_fingerprint
    assert_equal AgentPrograms::BootstrapBundledDefaultService::DEFAULT_DEPLOYMENT_BEARER, reconciled.deployment_bearer_secret_ref
    assert_equal "inactive", reconciled.status
    assert_equal "unknown", reconciled.health_status
    assert_equal AgentDeployments::REQUIRED_METHODS, reconciled.supported_methods
    assert_equal({}, reconciled.manifest_snapshot)
    assert_equal({}, reconciled.schema_snapshot)
    assert_equal({}, reconciled.capability_snapshot)
    assert_equal({}, reconciled.inspection_details)
    refute program.reload.selectable_for_conversation?
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
