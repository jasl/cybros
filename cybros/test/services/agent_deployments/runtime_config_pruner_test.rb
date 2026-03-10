require "test_helper"
require "fileutils"

class AgentDeployments::RuntimeConfigPrunerTest < ActiveSupport::TestCase
  setup do
    @workspace_root = Dir.mktmpdir("cybros-runtime-pruner-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  test "prune removes orphaned managed deployment runtime config directories" do
    active_dir = runtime_config_dir_for("active-deployment")
    stale_dir = runtime_config_dir_for("stale-deployment")
    FileUtils.mkdir_p(active_dir)
    FileUtils.mkdir_p(stale_dir)
    File.write(File.join(active_dir, "runtime.json"), "{}")
    File.write(File.join(stale_dir, "runtime.json"), "{}")

    create_managed_deployment!(deployment_id: "active-deployment", runtime_config_dir: active_dir)

    result = AgentDeployments::RuntimeConfigPruner.new(workspace_root: @workspace_root).prune!

    assert_equal Pathname.new(@workspace_root).cleanpath.to_s, result.fetch(:workspace_root)
    assert_equal ["active-deployment"], result.fetch(:kept_deployment_ids)
    assert_equal ["stale-deployment"], result.fetch(:removed_deployment_ids)
    assert File.directory?(active_dir), "expected active runtime config directory to remain"
    refute File.exist?(stale_dir), "expected orphaned runtime config directory to be removed"
  end

  test "prune dry run reports orphaned runtime config directories without deleting them" do
    stale_dir = runtime_config_dir_for("stale-deployment")
    FileUtils.mkdir_p(stale_dir)
    File.write(File.join(stale_dir, "runtime.json"), "{}")

    result = AgentDeployments::RuntimeConfigPruner.new(workspace_root: @workspace_root, dry_run: true).prune!

    assert_equal ["stale-deployment"], result.fetch(:removed_deployment_ids)
    assert_equal true, result.fetch(:dry_run)
    assert File.directory?(stale_dir), "expected dry run to keep the orphaned runtime config directory"
  end

  test "prune without a configured root is a no-op" do
    RuntimeSetting.delete_all

    with_default_agent_workspace_root("") do
      result = AgentDeployments::RuntimeConfigPruner.new.prune!

      assert_equal 0, result.fetch(:scanned_directory_count)
      assert_equal [], result.fetch(:removed_deployment_ids)
      assert_equal false, result.fetch(:configured_workspace_root)
    end
  end

  private

    def runtime_config_dir_for(deployment_id)
      File.join(@workspace_root, ".cybros", "agent_deployments", deployment_id)
    end

    def create_managed_deployment!(deployment_id:, runtime_config_dir:)
      program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

      AgentDeployment.create!(
        id: deployment_id,
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:v1:#{deployment_id}",
        status: "inactive",
        health_status: "unknown",
        protocol_version: AgentDeployments::SUPPORTED_PROTOCOL_VERSION,
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        transport_config: {
          "host" => "127.0.0.1",
          "port" => 4319,
          "rpc_path" => "/rpc",
          "runtime_config_path" => File.join(runtime_config_dir, "runtime.json"),
        },
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
      )
    end
end
