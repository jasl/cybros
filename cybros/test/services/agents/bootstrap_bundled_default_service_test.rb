require "test_helper"
require "open3"
require "timeout"

class Agents::BootstrapBundledDefaultServiceTest < ActiveSupport::TestCase
  setup do
    @workspace_root = Dir.mktmpdir("cybros-bootstrap-workspaces-")
    @fixture_source_root = Dir.mktmpdir("cybros-bootstrap-source-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
    FileUtils.rm_rf(@fixture_source_root) if @fixture_source_root.present?
  end

  test "bootstrap delegates to ensure_agent" do
    service = Agents::BootstrapBundledDefaultService.new
    service.define_singleton_method(:ensure_agent!) { :bootstrapped_agent }

    assert_equal :bootstrapped_agent, service.bootstrap!
  end

  test "runtime config requires explicit bundled claw bootstrap env" do
    with_env(
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => nil,
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER" => nil,
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT" => nil,
    ) do
      error =
        assert_raises(Agents::BundledDefaultRuntimeConfig::MissingBootstrapConfigError) do
          Agents::BundledDefaultRuntimeConfig.resolve
        end

      assert_includes error.message, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL"
    end
  end

  test "ensure_agent fails fast before creating the bundled claw row when bootstrap env is missing" do
    with_env(
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => nil,
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER" => nil,
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT" => nil,
    ) do
      assert_no_changes -> { Agent.where(source_kind: "bundled", bundled_agent_key: "claw").count } do
        assert_raises(Agents::BundledDefaultRuntimeConfig::MissingBootstrapConfigError) do
          Agents::BootstrapBundledDefaultService.ensure_agent!
        end
      end
    end
  end

  test "ensure_agent provisions the claw bundled source as the external bundled default" do
    with_default_agent_workspace_root(@workspace_root) do
      agent = Agents::BootstrapBundledDefaultService.ensure_agent!

      assert_equal "claw", agent.bundled_agent_key
      assert_equal "claw", agent.manifest_snapshot.fetch("agent_key")
      refute agent.manifest_snapshot.key?("agent_program_key")
      assert_equal "bundled", agent.source_kind
      assert_equal Agents::BundledSources.path_for("claw").to_s, agent.absolute_local_path.to_s
      assert_equal "http_jsonrpc", agent.transport_kind
      assert_equal TestSupport::BundledClawTestRuntime::TEST_FINGERPRINT, agent.deployment_fingerprint
      assert_equal Agents::BundledSources.path_for("claw").join("prompts/AGENT.md").read, agent.workspace_root_path.join("AGENTS.md").read
      assert_predicate agent.workspace_root_path.join("SOUL.md"), :file?
      assert_predicate agent.workspace_root_path.join("USER.md"), :file?
      assert_predicate agent.workspace_root_path.join("MEMORY.md"), :file?
      assert_predicate agent.workspace_root_path.join("memory"), :directory?
      assert_predicate agent.workspace_root_path.join("memory", Date.current.strftime("%Y-%m-%d.md")), :file?
    end
  end

  test "ensure_agent reconciles the bundled claw deployment from bootstrap env" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: {
          "agent_key" => "claw",
          "agent_deployment_key" => "claw",
          "deployment_fingerprint" => "deployment:bundled-claw:dev",
        },
        required_bearer: "secret://bundled-claw:dev",
      ).start

    with_default_agent_workspace_root(@workspace_root) do
      with_env(
        "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => server.rpc_url,
        "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER" => "secret://bundled-claw:dev",
        "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT" => "deployment:bundled-claw:dev",
      ) do
        agent = Agents::BootstrapBundledDefaultService.ensure_agent!

        assert_equal server.rpc_url, agent.endpoint_url
        assert_equal "secret://bundled-claw:dev", agent.deployment_bearer_secret_ref
        assert_equal "deployment:bundled-claw:dev", agent.deployment_fingerprint
        assert_equal "claw", agent.manifest_snapshot.fetch("agent_key")
      end
    end
  ensure
    server&.shutdown
  end

  test "ensure_agent re-activates an existing inactive bundled claw row before it is selectable" do
    with_default_agent_workspace_root(@workspace_root) do
      agent = Agents::BootstrapBundledDefaultService.ensure_agent!
      agent.update!(
        status: "inactive",
        health_status: "unknown",
        activated_at: nil,
        deactivated_at: Time.current.change(usec: 0),
      )

      refreshed = Agents::BootstrapBundledDefaultService.ensure_agent!

      assert_equal agent.id, refreshed.id
      assert_equal "active", refreshed.status
      assert_equal "healthy", refreshed.health_status
      assert_predicate refreshed, :selectable_for_conversation?
    end
  end

  test "workspace bootstrap seeds bundled skills once and keeps live files as the source of truth afterwards" do
    FileUtils.mkdir_p(File.join(@fixture_source_root, "prompts"))
    FileUtils.mkdir_p(File.join(@fixture_source_root, "skills", "example-skill"))
    File.write(File.join(@fixture_source_root, "prompts", "AGENT.md"), "Seed agent\n")
    File.write(File.join(@fixture_source_root, "prompts", "SOUL.md"), "Seed soul\n")
    File.write(File.join(@fixture_source_root, "prompts", "USER.md"), "Seed user\n")
    File.write(File.join(@fixture_source_root, "prompts", "system.md.liquid"), "Seed system\n")
    File.write(File.join(@fixture_source_root, "skills", "example-skill", "SKILL.md"), "Seed skill\n")

    destination_root = Pathname.new(@workspace_root).join("claw-fixture")

    Agents::WorkspaceBootstrap.seed!(source_root: Pathname.new(@fixture_source_root), destination_root: destination_root)

    assert_equal "Seed agent\n", destination_root.join("AGENTS.md").read
    assert_equal "Seed soul\n", destination_root.join("SOUL.md").read
    assert_equal "Seed user\n", destination_root.join("USER.md").read
    assert_equal "Seed skill\n", destination_root.join("skills/example-skill/SKILL.md").read
    assert_predicate destination_root.join("memory"), :directory?
    assert_predicate destination_root.join("memory", Date.current.strftime("%Y-%m-%d.md")), :file?

    destination_root.join("SOUL.md").write("Live soul\n")
    File.write(File.join(@fixture_source_root, "prompts", "SOUL.md"), "Changed bundled soul\n")

    Agents::WorkspaceBootstrap.seed!(source_root: Pathname.new(@fixture_source_root), destination_root: destination_root)

    assert_equal "Live soul\n", destination_root.join("SOUL.md").read
  end

  test "workspace bootstrap works from a fresh rails runner process" do
    FileUtils.mkdir_p(File.join(@fixture_source_root, "prompts"))
    File.write(File.join(@fixture_source_root, "prompts", "AGENT.md"), "Seed agent\n")
    File.write(File.join(@fixture_source_root, "prompts", "SOUL.md"), "Seed soul\n")
    File.write(File.join(@fixture_source_root, "prompts", "USER.md"), "Seed user\n")

    destination_root = Pathname.new(@workspace_root).join("fresh-runner")
    runner_script = <<~RUBY
      Agents::WorkspaceBootstrap.seed!(
        source_root: Pathname.new(ENV.fetch("WORKSPACE_BOOTSTRAP_SOURCE_ROOT")),
        destination_root: Pathname.new(ENV.fetch("WORKSPACE_BOOTSTRAP_DESTINATION_ROOT")),
      )
    RUBY

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "WORKSPACE_BOOTSTRAP_SOURCE_ROOT" => @fixture_source_root,
            "WORKSPACE_BOOTSTRAP_DESTINATION_ROOT" => destination_root.to_s,
          },
          "bin/rails",
          "runner",
          runner_script,
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?, [stdout, stderr].join("\n")
    assert_equal "Seed agent\n", destination_root.join("AGENTS.md").read
    assert_equal "Seed soul\n", destination_root.join("SOUL.md").read
    assert_equal "Seed user\n", destination_root.join("USER.md").read
  end

  test "workspace bootstrap reloads claw bootstrap constants when nested files were unloaded" do
    FileUtils.mkdir_p(File.join(@fixture_source_root, "prompts"))
    File.write(File.join(@fixture_source_root, "prompts", "AGENT.md"), "Seed agent\n")
    File.write(File.join(@fixture_source_root, "prompts", "SOUL.md"), "Seed soul\n")
    File.write(File.join(@fixture_source_root, "prompts", "USER.md"), "Seed user\n")

    destination_root = Pathname.new(@workspace_root).join("reloaded-constants")

    remove_claw_bootstrap_constant!(:WorkspaceBootstrap)
    remove_claw_bootstrap_constant!(:DailyMemoryTarget)

    Agents::WorkspaceBootstrap.seed!(source_root: Pathname.new(@fixture_source_root), destination_root: destination_root)

    assert_equal "Seed agent\n", destination_root.join("AGENTS.md").read
    assert_equal "Seed soul\n", destination_root.join("SOUL.md").read
    assert_equal "Seed user\n", destination_root.join("USER.md").read
    assert_predicate destination_root.join("memory", Date.current.strftime("%Y-%m-%d.md")), :file?
  ensure
    restore_claw_bootstrap_constants!
  end

  test "main app autoloads bundled claw workspace bootstrap in a fresh rails runner process" do
    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          "bin/rails",
          "runner",
          "puts defined?(Cybros::Agents::Claw::WorkspaceBootstrap).inspect",
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?, [stdout, stderr].join("\n")
    assert_equal "\"constant\"", stdout.strip
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

    def remove_claw_bootstrap_constant!(name)
      return unless defined?(Cybros::Agents::Claw)
      return unless Cybros::Agents::Claw.const_defined?(name, false)

      Cybros::Agents::Claw.send(:remove_const, name)
    end

    def restore_claw_bootstrap_constants!
      load_claw_support_file!("daily_memory_target") unless defined?(Cybros::Agents::Claw::DailyMemoryTarget)
      load_claw_support_file!("workspace_bootstrap") unless defined?(Cybros::Agents::Claw::WorkspaceBootstrap)
    end

    def load_claw_support_file!(basename)
      load Rails.root.join("../agents/claw/lib/cybros/agents/claw/#{basename}.rb").expand_path.to_s
    end
end
