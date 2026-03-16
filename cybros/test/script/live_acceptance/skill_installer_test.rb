require "test_helper"
require "stringio"
require "tmpdir"

ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] = "1"
require Rails.root.join("script/live_acceptance/agent_root_workspace")

class SkillInstallerLiveAcceptanceTest < ActiveSupport::TestCase
  test "system skill-installer guidance prefers repo-root batch installs through skills_install" do
    skill_text = Rails.root.join("skills/.system/skill-installer/SKILL.md").read

    assert_includes skill_text, "call `skills_install` with `repo` and no `path` first"
    assert_includes skill_text, "installing all discovered skills from that repo in one protected batch"
    assert_includes skill_text, "instead of manually enumerating files or asking the user to choose one skill by default"
  end

  test "write_installable_skill! creates a deterministic fixture with a canonical source hash" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)

    Dir.mktmpdir("cybros-live-installer-fixture-") do |root|
      fixture =
        runner.send(
          :write_installable_skill!,
          root: Pathname.new(root),
          relative_path: "skills/catalog-answer",
          skill_name: "catalog-answer",
          description: "Returns FIXTURE_TOKEN",
          answer_token: "FIXTURE_TOKEN",
        )

      manifest = Agents::SkillInstallation::Manifest.build(skill_root: Pathname.new(fixture.fetch(:skill_root)))

      assert_equal "catalog-answer", fixture.fetch(:skill_name)
      assert_equal manifest.fetch(:package_sha256), fixture.fetch(:source_sha256)
      assert_includes Pathname.new(fixture.fetch(:skill_root)).join("SKILL.md").read, "FIXTURE_TOKEN"
    end
  end

  test "with_skill_catalog_sources temporarily exposes runtime catalog sources and restores the prior env" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    original = ENV["CYBROS_SKILL_CATALOG_SOURCES"]
    seen = nil
    sources = [{ "catalog" => "live-acceptance", "root" => "/tmp/catalog-root" }]

    runner.send(:with_skill_catalog_sources, sources) do
      seen = RuntimeSetting.skill_catalog_sources
    end

    assert_equal sources, seen
    if original.nil?
      assert_nil ENV["CYBROS_SKILL_CATALOG_SOURCES"]
    else
      assert_equal original, ENV["CYBROS_SKILL_CATALOG_SOURCES"]
    end
  end
end
