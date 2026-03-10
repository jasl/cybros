module AgentPrograms
  class BootstrapBundledDefaultService
    DEFAULT_BUNDLED_AGENT_KEY = "default".freeze
    DEFAULT_PROGRAM_NAME = "Default".freeze
    TEST_DEPLOYMENT_FINGERPRINT = "deployment:bundled-default:test".freeze
    TEST_DEPLOYMENT_BEARER = "secret://bundled-default:test".freeze

    def self.ensure_program!
      Creator.create_from_bundled_source!(
        name: DEFAULT_PROGRAM_NAME,
        bundled_agent_key: DEFAULT_BUNDLED_AGENT_KEY,
      )
    end

    def self.bootstrap!
      return new.ensure_test_runtime! if Rails.env.test?

      ensure_program!
    end

    def self.ensure_test_runtime!
      return unless Rails.env.test?

      new.ensure_test_runtime!
    end

    def ensure_test_runtime!
      program = self.class.ensure_program!
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

    private

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
          name: "Bundled Default Target",
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
