module AgentPrograms
  class BootstrapBundledDefaultService
    DEFAULT_BUNDLED_AGENT_KEY = "default".freeze
    DEFAULT_PROGRAM_NAME = "Default".freeze
    DEFAULT_DEPLOYMENT_FINGERPRINT = "deployment:bundled-default:managed-local".freeze
    DEFAULT_DEPLOYMENT_BEARER = "secret://bundled-default:managed-local".freeze
    TEST_DEPLOYMENT_FINGERPRINT = "deployment:bundled-default:test".freeze
    TEST_DEPLOYMENT_BEARER = "secret://bundled-default:test".freeze
    DEFAULT_EXECUTION_LOCATION_NAME = "Bundled Default Local Host".freeze
    DEFAULT_WORKSPACE_NAME = "Bundled Default Workspace".freeze
    DEFAULT_EXECUTION_TARGET_NAME = "Bundled Default Target".freeze
    DEFAULT_ACTIVATION_TIMEOUT = 10.seconds

    def self.ensure_program!
      Creator.create_from_bundled_source!(
        name: DEFAULT_PROGRAM_NAME,
        bundled_agent_key: DEFAULT_BUNDLED_AGENT_KEY,
      )
    end

    def self.bootstrap!
      new.bootstrap!
    end

    def self.ensure_test_runtime!
      return unless Rails.env.test?

      new.ensure_test_runtime!
    end

    def self.managed_local_autolaunch_enabled?
      value = ENV.fetch("CYBROS_MANAGED_AGENT_AUTOLAUNCH", "")
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def self.ensure_managed_local_deployment!(program:, default_fingerprint:, default_bearer_secret_ref:)
      new.ensure_managed_local_deployment!(
        program: program,
        default_fingerprint: default_fingerprint,
        default_bearer_secret_ref: default_bearer_secret_ref,
      )
    end

    def self.wait_for_managed_local_activation!(deployment:, timeout: DEFAULT_ACTIVATION_TIMEOUT)
      new.wait_for_managed_local_activation!(deployment: deployment, timeout: timeout)
    end

    def bootstrap!
      program = self.class.ensure_program!
      backfill_execution_capable_conversations!(program:)

      return ensure_test_runtime!(program:) if Rails.env.test?

      ensure_runtime_setting!
      ensure_default_execution_target! if self.class.managed_local_autolaunch_enabled?

      deployment =
        ensure_managed_local_deployment!(
          program: program,
          default_fingerprint: DEFAULT_DEPLOYMENT_FINGERPRINT,
          default_bearer_secret_ref: DEFAULT_DEPLOYMENT_BEARER,
        )

      if self.class.managed_local_autolaunch_enabled?
        wait_for_managed_local_activation!(deployment: deployment, timeout: DEFAULT_ACTIVATION_TIMEOUT)
      end

      program.reload
    end

    def ensure_test_runtime!(program: self.class.ensure_program!)
      ensure_test_execution_target!
      host = test_host
      deployment =
        AgentDeployment.find_or_initialize_by(
          agent_program: program,
          deployment_fingerprint: TEST_DEPLOYMENT_FINGERPRINT,
        )
      deployment.assign_attributes(
        transport_kind: "http_jsonrpc",
        endpoint_url: host.rpc_url,
        deployment_bearer_secret_ref: TEST_DEPLOYMENT_BEARER,
        contract_fingerprint: program.published_contract_fingerprint,
        status: "inactive",
        health_status: "unknown",
        protocol_version: AgentDeployments::SUPPORTED_PROTOCOL_VERSION,
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
      deployment.save!

      AgentDeployments::InspectionService.new(deployment: deployment).inspect!
      AgentDeployments::ActivationService.new(deployment: deployment).activate!
      deployment
    end

    def ensure_managed_local_deployment!(program:, default_fingerprint:, default_bearer_secret_ref:)
      ensure_runtime_setting!
      managed_deployment_for(program) ||
        AgentDeployments::RegistrationService.new(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "",
          deployment_bearer_secret_ref: default_bearer_secret_ref,
          deployment_fingerprint: default_fingerprint,
        ).register!
    end

    def wait_for_managed_local_activation!(deployment:, timeout:)
      deadline = timeout.from_now

      loop do
        deployment.reload
        return deployment if deployment.status == "active" && deployment.health_status == "healthy"

        if deadline.past?
          raise "managed local deployment failed to activate: #{deployment.id}"
        end

        sleep 0.1
      end
    end

    private

      def backfill_execution_capable_conversations!(program:)
        Conversation.where(agent_program_id: nil).update_all(
          agent_program_id: program.id,
          agent_config_schema_fingerprint: program.config_schema_fingerprint,
          updated_at: Time.current,
        )
      end

      def ensure_runtime_setting!
        runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
        runtime_setting.assign_attributes(
          default_worker_concurrency: runtime_setting.default_worker_concurrency.presence || RuntimeSetting::DEFAULT_WORKER_CONCURRENCY,
          queue_overrides: runtime_setting.queue_overrides.presence || {},
          alert_thresholds: runtime_setting.alert_thresholds.presence || {},
          agent_workspace_root: runtime_setting.agent_workspace_root.presence || RuntimeSetting::DEFAULT_AGENT_WORKSPACE_ROOT,
        )
        runtime_setting.save!
        runtime_setting
      end

      def managed_deployment_for(program)
        program.agent_deployments.order(created_at: :desc).detect do |deployment|
          deployment.transport_kind.to_s == "http_jsonrpc" && deployment.runtime_config_path.present?
        end
      end

      def ensure_default_execution_target!
        return if ExecutionTarget.visible_for_runtime.exists?

        location =
          ExecutionLocation.find_or_create_by!(name: DEFAULT_EXECUTION_LOCATION_NAME) do |record|
            record.kind = "host"
            record.platform = "macos_arm64"
            record.status = "active"
            record.trust_group = "operator"
            record.environment = Rails.env
            record.tags = ["bundled-default", Rails.env]
            record.max_concurrent_tasks = 4
            record.max_queued_tasks = 16
            record.default_timeout_s = 900
          end
        workspace =
          Workspace.find_or_create_by!(execution_location: location, name: DEFAULT_WORKSPACE_NAME) do |record|
            record.root_path = default_execution_workspace_root.to_s
            record.workspace_type = "git"
            record.status = "active"
            record.capability_tags = ["git", "shell"]
            record.tags = ["bundled-default", Rails.env]
          end

        ExecutionTarget.find_or_create_by!(execution_location: location, workspace: workspace, name: DEFAULT_EXECUTION_TARGET_NAME) do |record|
          record.status = "active"
          record.sandboxed = true
        end
      end

      def default_execution_workspace_root
        env_root = ENV.fetch("CYBROS_DEFAULT_EXECUTION_WORKSPACE_ROOT", "").to_s.strip
        return Pathname.new(env_root) if env_root.present?

        Rails.root
      end

      def ensure_test_execution_target!
        return if ExecutionTarget.visible_for_runtime.exists?

        location =
          ExecutionLocation.create!(
            name: "Bundled default test host",
            kind: "host",
            platform: "macos_arm64",
            status: "active",
            trust_group: "operator",
            environment: "test",
            tags: ["bundled-default"],
            max_concurrent_tasks: 4,
            max_queued_tasks: 16,
            default_timeout_s: 900,
          )
        workspace =
          Workspace.create!(
            execution_location: location,
            name: "Bundled default test workspace",
            root_path: Rails.root.join("tmp", "bundled-default-test-workspace").to_s,
            workspace_type: "git",
            status: "active",
            capability_tags: ["git"],
            tags: ["bundled-default"],
          )
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: DEFAULT_EXECUTION_TARGET_NAME,
          status: "active",
          sandboxed: true,
        )
      end

      def test_host
        self.class.instance_variable_get(:@test_host) ||
          self.class.instance_variable_set(
            :@test_host,
            Cybros::BundledAgentHost::Application.new(
              source_root: Rails.root.join("agents/default"),
              deployment_fingerprint: TEST_DEPLOYMENT_FINGERPRINT,
              required_bearer: TEST_DEPLOYMENT_BEARER,
            ).start,
          )
      end
  end
end
