require "test_helper"
require "fileutils"
require "yaml"

module Cybros
  module ManagedAgentDeployments
    class SupervisorTest < ActiveSupport::TestCase
      teardown do
        @supervisor&.shutdown!
        FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
      end

      test "tick activates a managed local custom deployment from generated runtime config" do
        @workspace_root = Dir.mktmpdir("cybros-managed-agent-workspace-")
        configure_runtime_setting!(@workspace_root)

        source_root = Pathname.new(@workspace_root).join("managed-local-agent")
        FileUtils.copy_entry(Rails.root.join("agents/default").to_s, source_root.to_s, false, false, true)
        FileUtils.rm_rf(source_root.join(".git"))
        rewrite_manifest!(
          source_root: source_root,
          agent_program_key: "managed-local-agent",
          name: "Managed Local Agent",
          config_namespace: "managed.local.agent",
        )

        loaded = AgentPrograms::Loader.new(base_dir: source_root).load
        program =
          AgentProgram.create!(
            name: "Managed Local Agent",
            description: loaded.manifest["description"],
            source_kind: "custom",
            local_path: "managed-local-agent",
            manifest_snapshot: loaded.manifest,
            config_namespace: loaded.manifest.fetch("config_namespace"),
            published_contract_fingerprint: AgentPrograms::Creator.bundled_contract_fingerprint(loaded.manifest),
            global_config: {},
            global_config_schema: loaded.manifest.fetch("global_config_schema", {}),
            conversation_config_schema: loaded.manifest.fetch("conversation_config_schema", {}),
            config_schema_fingerprint: AgentPrograms::Creator.bundled_config_schema_fingerprint(loaded.manifest),
            args: {
              "runtime_surface" => loaded.runtime_surface_config,
              "runtime_surface_status" => loaded.runtime_surface_status,
            },
          )

        deployment =
          AgentDeployments::RegistrationService.new(
            agent_program: program,
            transport_kind: "http_jsonrpc",
            endpoint_url: "",
            deployment_bearer_secret_ref: "secret://managed-local:test",
            deployment_fingerprint: "deployment:managed-local:test",
          ).register!

        @supervisor = Supervisor.new(poll_interval_s: 0.05, out: File::NULL, err: File::NULL)

        120.times do
          @supervisor.tick!
          deployment.reload
          break if deployment.status == "active" && deployment.health_status == "healthy"

          sleep 0.05
        end

        assert_equal "active", deployment.reload.status
        assert_equal "healthy", deployment.reload.health_status
        assert_equal "http://127.0.0.1:#{deployment.allocated_port}/rpc", deployment.endpoint_url
        assert File.exist?(deployment.runtime_config_path), "expected runtime config to exist"
      end

      private

        def configure_runtime_setting!(root)
          runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
          runtime_setting.assign_attributes(
            default_worker_concurrency: RuntimeSetting::DEFAULT_WORKER_CONCURRENCY,
            queue_overrides: {},
            alert_thresholds: {},
            agent_workspace_root: root,
          )
          runtime_setting.save!
        end

        def rewrite_manifest!(source_root:, agent_program_key:, name:, config_namespace:)
          manifest_path = source_root.join("agent.yml")
          manifest = YAML.safe_load(manifest_path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
          manifest["agent_program_key"] = agent_program_key
          manifest["name"] = name
          manifest["config_namespace"] = config_namespace
          manifest_path.write(YAML.dump(manifest))
        end
    end
  end
end
