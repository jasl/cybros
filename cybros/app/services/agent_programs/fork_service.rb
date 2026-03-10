require "fileutils"
require "yaml"

module AgentPrograms
  class ForkService
    TEST_DEPLOYMENT_BEARER_PREFIX = "secret://forked-agent:test".freeze

    def self.call!(source_program:, name:)
      new(source_program: source_program, name: name).call!
    end

    def initialize(source_program:, name:)
      @source_program = source_program
      @name = name.to_s.strip
    end

    def call!
      raise ArgumentError, "fork name is required" if name.blank?
      raise ArgumentError, "only bundled sources can be forked" unless source_program.bundled_source?

      workspace_root = configured_workspace_root
      relative_local_path = unique_relative_local_path
      destination_root = workspace_root.join(relative_local_path)
      custom_agent_key = "custom-#{SecureRandom.hex(6)}"
      config_namespace = "custom.#{custom_agent_key}"

      copy_source_tree!(destination_root)
      rewrite_manifest!(destination_root:, custom_agent_key:, config_namespace:)
      GitBootstrap.bootstrap!(
        source_root: destination_root,
        import_tag: "cybros-import/#{source_program.bundled_agent_key}",
      )

      loaded = AgentPrograms::Loader.new(base_dir: destination_root).load
      manifest = loaded.manifest
      program =
        AgentProgram.create!(
          name: name,
          description: manifest["description"],
          source_kind: "custom",
          local_path: relative_local_path,
          forked_from_agent_program: source_program,
          manifest_snapshot: manifest,
          config_namespace: manifest.fetch("config_namespace", config_namespace),
          published_contract_fingerprint: AgentPrograms::Creator.bundled_contract_fingerprint(manifest),
          global_config: {},
          global_config_schema: manifest.fetch("global_config_schema", {}),
          conversation_config_schema: manifest.fetch("conversation_config_schema", {}),
          config_schema_fingerprint: AgentPrograms::Creator.bundled_config_schema_fingerprint(manifest),
          args: {
            "runtime_surface" => loaded.runtime_surface_config,
            "runtime_surface_status" => loaded.runtime_surface_status,
          },
        )
      if Rails.env.test?
        activate_test_deployment!(program:)
      else
        deployment =
          AgentPrograms::BootstrapBundledDefaultService.ensure_managed_local_deployment!(
            program: program,
            default_fingerprint: "deployment:#{program.id}:managed-local",
            default_bearer_secret_ref: "secret://managed-local:#{program.id}",
          )
        if AgentPrograms::BootstrapBundledDefaultService.managed_local_autolaunch_enabled?
          AgentPrograms::BootstrapBundledDefaultService.wait_for_managed_local_activation!(deployment: deployment)
        end
      end
      program
    end

    private

      attr_reader :source_program, :name

      def configured_workspace_root
        RuntimeSetting.instance_agent_workspace_root_path
      end

      def unique_relative_local_path
        base = name.parameterize(separator: "-")
        base = "forked-agent" if base.blank?
        "#{base}-#{SecureRandom.hex(4)}"
      end

      def copy_source_tree!(destination_root)
        FileUtils.mkdir_p(destination_root.parent)
        FileUtils.copy_entry(source_program.absolute_local_path.to_s, destination_root.to_s, false, false, true)
        FileUtils.rm_rf(destination_root.join(".git"))
      end

      def rewrite_manifest!(destination_root:, custom_agent_key:, config_namespace:)
        manifest_path = destination_root.join("agent.yml")
        manifest = YAML.safe_load(manifest_path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
        manifest = manifest.is_a?(Hash) ? manifest : {}
        manifest["agent_program_key"] = custom_agent_key
        manifest["name"] = name
        manifest["config_namespace"] = config_namespace
        manifest_path.write(YAML.dump(manifest))
      end

      def activate_test_deployment!(program:)
        host = test_host_for(program)
        fingerprint = "deployment:#{program.id}:test"
        bearer = "#{TEST_DEPLOYMENT_BEARER_PREFIX}:#{program.id}"
        deployment =
          AgentDeployment.find_or_initialize_by(
            agent_program: program,
            deployment_fingerprint: fingerprint,
          )
        deployment.assign_attributes(
          transport_kind: "http_jsonrpc",
          endpoint_url: host.rpc_url,
          deployment_bearer_secret_ref: bearer,
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
      end

      def test_host_for(program)
        hosts = self.class.instance_variable_get(:@test_hosts) || self.class.instance_variable_set(:@test_hosts, {})
        hosts[program.id] ||=
          Cybros::BundledAgentHost::Application.new(
            source_root: program.absolute_local_path,
            deployment_fingerprint: "deployment:#{program.id}:test",
            required_bearer: "#{TEST_DEPLOYMENT_BEARER_PREFIX}:#{program.id}",
          ).start
      end
  end
end
