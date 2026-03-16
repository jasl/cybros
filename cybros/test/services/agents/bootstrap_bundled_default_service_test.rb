require "test_helper"

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

  test "ensure_agent provisions the claw bundled source as the managed local default" do
    with_default_agent_workspace_root(@workspace_root) do
      agent = Agents::BootstrapBundledDefaultService.ensure_agent!

      assert_equal "claw", agent.bundled_agent_key
      assert_equal "bundled", agent.source_kind
      assert_equal Rails.root.join("agents/claw").to_s, agent.absolute_local_path.to_s
      assert_equal "http_jsonrpc", agent.transport_kind
      assert_equal "deployment:bundled-claw:test", agent.deployment_fingerprint if Rails.env.test?
      assert_equal Rails.root.join("agents/claw/prompts/AGENT.md").read, agent.workspace_root_path.join("AGENTS.md").read
      assert_predicate agent.workspace_root_path.join("SOUL.md"), :file?
      assert_predicate agent.workspace_root_path.join("USER.md"), :file?
      assert_predicate agent.workspace_root_path.join("MEMORY.md"), :file?
      assert_predicate agent.workspace_root_path.join("memory"), :directory?
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

    destination_root.join("SOUL.md").write("Live soul\n")
    File.write(File.join(@fixture_source_root, "prompts", "SOUL.md"), "Changed bundled soul\n")

    Agents::WorkspaceBootstrap.seed!(source_root: Pathname.new(@fixture_source_root), destination_root: destination_root)

    assert_equal "Live soul\n", destination_root.join("SOUL.md").read
  end
end
