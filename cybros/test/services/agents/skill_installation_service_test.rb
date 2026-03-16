require "test_helper"
require "tmpdir"

class Agents::SkillInstallationServiceTest < ActiveSupport::TestCase
  test "source fetcher normalizes github repository identifiers before staging" do
    fetcher =
      Class.new(Agents::SkillInstallation::SourceFetcher) do
        attr_reader :captured

        def initialize
          super(catalog_sources: [])
          @captured = []
        end

        private

          def fetch_github_with_git!(repo:, ref:, destination:, path:)
            @captured << {
              repo: repo,
              ref: ref,
              destination: destination.to_s,
              path: path,
            }
            FileUtils.mkdir_p(destination)
          end
      end.new

    fetcher.fetch!(
      source_kind: "github",
      repo: "https://github.com/obra/superpowers",
      ref: "main",
      path: "skills/example-skill",
    )
    fetcher.fetch!(
      source_kind: "github",
      repo: "obra/superpowers",
      ref: "main",
      path: "skills/example-skill",
    )

    assert_equal %w[obra/superpowers obra/superpowers], fetcher.captured.map { |entry| entry.fetch(:repo) }
  end

  test "source fetcher clones full github repos for repo-root installs and keeps sparse checkout for path installs" do
    fetcher =
      Class.new(Agents::SkillInstallation::SourceFetcher) do
        attr_reader :captured

        def initialize
          super(catalog_sources: [])
          @captured = []
        end

        private

          def run_git!(*command)
            @captured << command
            if command.first == "clone"
              destination = command.last
              FileUtils.mkdir_p(destination)
            end

            ""
          end
      end.new

    fetcher.fetch!(source_kind: "github", repo: "obra/superpowers", ref: "main", path: nil)
    fetcher.fetch!(source_kind: "github", repo: "obra/superpowers", ref: "main", path: "skills/example-skill")

    repo_root_clone = fetcher.captured[0]
    repo_root_checkout = fetcher.captured[1]
    path_clone = fetcher.captured[2]
    path_checkout = fetcher.captured[3]
    path_sparse = fetcher.captured[4]

    assert_equal ["clone", "--filter=blob:none"], repo_root_clone.first(2)
    refute_includes repo_root_clone, "--sparse"
    assert_equal ["-C", repo_root_clone.last, "checkout", "main"], repo_root_checkout

    assert_equal ["clone", "--filter=blob:none", "--sparse"], path_clone.first(3)
    assert_equal ["-C", path_clone.last, "checkout", "main"], path_checkout
    assert_equal ["-C", path_clone.last, "sparse-checkout", "set", "--no-cone", "skills/example-skill"], path_sparse
  end

  test "prepare fails closed when install target collides with a platform skill" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")

        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Collision")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "catalog",
                catalog: "curated",
                catalog_entry: "platform-skill",
                install_as: "platform-skill",
                platform_skill_dirs: [platform_skills_root],
              )
            end

          assert_equal "cybros.skills_install.destination_conflicts_with_platform_skill", error.code
          assert_equal "platform-skill", error.details[:skill_name]
        end
      end
    end
  end

  test "prepare stages a github skill source and computes a deterministic manifest without touching the live root" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Prepare staged skill")
          skill_root = write_staged_skill!(stage_root, name: "example-skill")

          result =
            Agents::SkillInstallationService.prepare(
              agent: conversation.agent,
              source_kind: "github",
              repo: "openai/skills",
              ref: "main",
              path: "skills/example-skill",
              source_fetcher: stub_fetcher(stage_root:, skill_root:),
            )

          assert_equal "prepared", result.fetch(:status)
          assert_equal "example-skill", result.fetch(:install_name)
          assert_equal stage_root, result.fetch(:stage_root)
          assert_equal skill_root.to_s, result.fetch(:skill_root)
          refute conversation.agent.workspace_root_path.join("skills", "example-skill").exist?

          manifest = result.fetch(:manifest)
          assert_equal "SKILL.md", manifest.fetch(:files).first.fetch(:path)
          assert_equal "references/guide.md", manifest.fetch(:files).last.fetch(:path)
          assert_equal manifest.fetch(:package_sha256), result.fetch(:source_sha256)
        end
      end
    end
  end

  test "prepare enters repo-root batch mode and prefers conventional skill layouts in deterministic order" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Prepare repo-root batch")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)

          write_staged_skill!(source_root.join("skills"), name: "zeta-skill")
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill")
          write_staged_skill!(source_root.join("skills/.system"), name: "system-helper")
          write_staged_skill!(source_root.join("examples"), name: "ignored-skill")

          result =
            Agents::SkillInstallationService.prepare(
              agent: conversation.agent,
              source_kind: "github",
              repo: "https://github.com/obra/superpowers",
              ref: "main",
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )

          assert_equal "repo_root_batch", result.fetch(:mode)
          assert_equal "obra/superpowers", result.fetch(:repo)
          assert_equal false, result.fetch(:replace)
          assert_equal(
            [
              "skills/.system/system-helper",
              "skills/alpha-skill",
              "skills/zeta-skill",
            ],
            result.fetch(:candidates).map { |candidate| candidate.fetch(:source_path) },
          )
        end
      end
    end
  end

  test "prepare falls back to limited-depth repo scanning only when preferred layouts are empty" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Prepare fallback repo-root batch")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root.join("skills"))

          write_staged_skill!(source_root.join("fallback"), name: "batch-skill")
          write_staged_skill!(source_root.join("too/deep/path"), name: "ignored-deep-skill")

          result =
            Agents::SkillInstallationService.prepare(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )

          assert_equal ["fallback/batch-skill"], result.fetch(:candidates).map { |candidate| candidate.fetch(:source_path) }
        end
      end
    end
  end

  test "prepare ignores hidden internal directories during repo-root fallback discovery" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Ignore hidden repo internals")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root.join("skills"))
          write_staged_skill!(source_root.join(".git"), name: "internal-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.invalid_skill_root", error.code
        end
      end
    end
  end

  test "prepare fails closed when repo-root staging discovers no installable skills" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Empty repo-root batch")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root.join("skills"))
          File.write(source_root.join("README.md"), "# not a skill repo\n")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.invalid_skill_root", error.code
        end
      end
    end
  end

  test "prepare normalizes repo-root candidates with install names manifests and explicit replacements" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Normalized repo-root batch")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "alpha-skill", description: "Existing local skill")

          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill")
          write_staged_skill!(source_root.join("skills/.system"), name: "system-helper")

          result =
            Agents::SkillInstallationService.prepare(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )

          assert_equal %w[system-helper alpha-skill], result.fetch(:candidates).map { |candidate| candidate.fetch(:install_name) }
          assert_equal [false, true], result.fetch(:candidates).map { |candidate| candidate.fetch(:replace) }
          result.fetch(:candidates).each do |candidate|
            assert_equal candidate.fetch(:manifest).fetch(:package_sha256), candidate.fetch(:source_sha256)
            assert_equal candidate.fetch(:install_name), Pathname.new(candidate.fetch(:skill_root)).basename.to_s
          end
        end
      end
    end
  end

  test "prepare rejects install_as for repo-root batch installs" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Invalid repo-root install_as")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                install_as: "renamed-skill",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.install_as_not_allowed", error.code
        end
      end
    end
  end

  test "prepare rejects repo-root candidates whose declared skill name does not match the directory" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Mismatched repo-root skill")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill", declared_name: "beta-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.skill_name_mismatch", error.code
        end
      end
    end
  end

  test "prepare rejects repo-root batches with duplicate install names" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Duplicate repo-root names")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "duplicate-skill")
          write_staged_skill!(source_root.join("skills/.system"), name: "duplicate-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.duplicate_install_name", error.code
        end
      end
    end
  end

  test "prepare rejects repo-root batches when a candidate collides with a platform skill" do
    Dir.mktmpdir("cybros-platform-skills-") do |platform_skills_root|
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
          write_skill!(platform_skills_root, name: "platform-skill", description: "Platform description")

          with_default_agent_workspace_root(workspace_root) do
            conversation = create_conversation!(title: "Platform repo-root collision")
            source_root = Pathname.new(stage_root).join("source")
            FileUtils.mkdir_p(source_root)
            write_staged_skill!(source_root.join("skills"), name: "platform-skill")
            write_staged_skill!(source_root.join("skills"), name: "safe-skill")

            error =
              assert_raises(AgentCore::ValidationError) do
                Agents::SkillInstallationService.prepare(
                  agent: conversation.agent,
                  source_kind: "github",
                  repo: "obra/superpowers",
                  platform_skill_dirs: [platform_skills_root],
                  source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
                )
              end

            assert_equal "cybros.skills_install.destination_conflicts_with_platform_skill", error.code
            assert_equal "platform-skill", error.details[:skill_name]
          end
        end
      end
    end
  end

  test "prepare rejects repo-root batches when an installed skill exists unless replace is true" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Existing repo-root collision")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "existing-skill", description: "Existing local skill")

          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "existing-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "obra/superpowers",
                source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              )
            end

          assert_equal "cybros.skills_install.destination_exists", error.code
        end
      end
    end
  end

  test "prepare rejects invalid repo-root candidate entries before approval" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        Dir.mktmpdir("cybros-external-") do |external_root|
          with_default_agent_workspace_root(workspace_root) do
            conversation = create_conversation!(title: "Invalid repo-root entry")
            source_root = Pathname.new(stage_root).join("source")
            FileUtils.mkdir_p(source_root)
            invalid_root = write_staged_skill!(source_root.join("skills"), name: "invalid-skill")
            File.write(Pathname.new(external_root).join("secret.txt"), "secret\n")
            File.symlink(Pathname.new(external_root).join("secret.txt"), invalid_root.join("assets/secret-link"))

            error =
              assert_raises(AgentCore::ValidationError) do
                Agents::SkillInstallationService.prepare(
                  agent: conversation.agent,
                  source_kind: "github",
                  repo: "obra/superpowers",
                  source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
                )
              end

            assert_equal "cybros.skills_install.invalid_skill_entry", error.code
          end
        end
      end
    end
  end

  test "prepare rejects staged sources without a SKILL.md before approval" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-invalid-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Invalid staged skill")
          skill_root = Pathname.new(stage_root).join("broken-skill")
          FileUtils.mkdir_p(skill_root)
          File.write(skill_root.join("README.md"), "# not a skill\n")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "openai/skills",
                ref: "main",
                path: "skills/broken-skill",
                source_fetcher: stub_fetcher(stage_root:, skill_root:),
              )
            end

          assert_equal "cybros.skills_install.invalid_skill_root", error.code
        end
      end
    end
  end

  test "prepare rejects staged sources containing traversal-capable symlinks before approval" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        Dir.mktmpdir("cybros-external-") do |external_root|
          with_default_agent_workspace_root(workspace_root) do
            conversation = create_conversation!(title: "Traversal skill")
            skill_root = write_staged_skill!(stage_root, name: "example-skill")
            File.write(Pathname.new(external_root).join("secret.txt"), "secret\n")
            File.symlink(Pathname.new(external_root).join("secret.txt"), skill_root.join("assets/secret-link"))

            error =
              assert_raises(AgentCore::ValidationError) do
                Agents::SkillInstallationService.prepare(
                  agent: conversation.agent,
                  source_kind: "github",
                  repo: "openai/skills",
                  ref: "main",
                  path: "skills/example-skill",
                  source_fetcher: stub_fetcher(stage_root:, skill_root:),
                )
              end

            assert_equal "cybros.skills_install.invalid_skill_entry", error.code
          end
        end
      end
    end
  end

  test "prepare rejects hash mismatches before approval" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Hash mismatch")
          skill_root = write_staged_skill!(stage_root, name: "example-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "openai/skills",
                ref: "main",
                path: "skills/example-skill",
                expected_sha256: "deadbeef",
                source_fetcher: stub_fetcher(stage_root:, skill_root:),
              )
            end

          assert_equal "cybros.skills_install.source_hash_mismatch", error.code
        end
      end
    end
  end

  test "prepare rejects an existing destination unless replace is true" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Destination exists")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "example-skill", description: "Existing local skill")
          skill_root = write_staged_skill!(stage_root, name: "example-skill")

          error =
            assert_raises(AgentCore::ValidationError) do
              Agents::SkillInstallationService.prepare(
                agent: conversation.agent,
                source_kind: "github",
                repo: "openai/skills",
                ref: "main",
                path: "skills/example-skill",
                source_fetcher: stub_fetcher(stage_root:, skill_root:),
              )
            end

          assert_equal "cybros.skills_install.destination_exists", error.code

          result =
            Agents::SkillInstallationService.prepare(
              agent: conversation.agent,
              source_kind: "github",
              repo: "openai/skills",
              ref: "main",
              path: "skills/example-skill",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root:),
            )

          assert_equal true, result.fetch(:replace)
        end
      end
    end
  end

  test "install replaces an existing agent-local skill with a history snapshot and provenance" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Replace installed skill")
          existing_root = conversation.agent.workspace_root_path.join("skills", "example-skill")
          FileUtils.mkdir_p(existing_root)
          File.write(
            existing_root.join("SKILL.md"),
            <<~MD,
              ---
              name: example-skill
              description: Existing description
              ---

              # example-skill
            MD
          )

          skill_root = write_staged_skill!(stage_root, name: "example-skill", description: "Replacement description")

          result =
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "openai/skills",
              ref: "main",
              path: "skills/example-skill",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root:),
            )

          installed_skill = result.fetch(:installed_skills).first
          assert_equal "single_skill", result.fetch(:mode)
          assert_equal 1, result.fetch(:installed_count)
          assert_equal conversation.agent.workspace_root_path.join("skills", "example-skill").to_s, installed_skill.fetch(:live_path)
          assert_match %r{/.history/skills/example-skill/}, installed_skill.fetch(:snapshot_path)
          assert_match %r{/.state/skills/example-skill\.json\z}, installed_skill.fetch(:provenance_path)
          assert_equal installed_skill.fetch(:source_sha256), installed_skill.fetch(:installed_sha256)
          assert_includes File.read(existing_root.join("SKILL.md")), "Replacement description"
          assert_includes File.read(Pathname.new(installed_skill.fetch(:snapshot_path)).join("SKILL.md")), "Existing description"
        end
      end
    end
  end

  test "installing a new skill writes provenance but does not create an empty snapshot" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Install new skill")
          skill_root = write_staged_skill!(stage_root, name: "new-skill", description: "New description")

          result =
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "openai/skills",
              ref: "main",
              path: "skills/new-skill",
              source_fetcher: stub_fetcher(stage_root:, skill_root:),
            )

          installed_skill = result.fetch(:installed_skills).first
          assert_equal conversation.agent.workspace_root_path.join("skills", "new-skill").to_s, installed_skill.fetch(:live_path)
          assert_nil installed_skill[:snapshot_path]
          assert_predicate Pathname.new(installed_skill.fetch(:provenance_path)), :file?
          refute_includes installed_skill.fetch(:provenance_path), "/skills/new-skill/"
        end
      end
    end
  end

  test "install failures do not leave partially promoted live files behind" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-skill-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Promotion failure")
          existing_root = conversation.agent.workspace_root_path.join("skills", "example-skill")
          FileUtils.mkdir_p(existing_root)
          File.write(
            existing_root.join("SKILL.md"),
            <<~MD,
              ---
              name: example-skill
              description: Existing description
              ---

              # example-skill
            MD
          )
          skill_root = write_staged_skill!(stage_root, name: "example-skill", description: "Replacement description")

          file_utils = failing_file_utils

          assert_raises(RuntimeError) do
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "openai/skills",
              ref: "main",
              path: "skills/example-skill",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root:),
              file_utils: file_utils,
            )
          end

          assert_includes File.read(existing_root.join("SKILL.md")), "Existing description"
          assert_equal [], Dir.glob(conversation.agent.workspace_root_path.join("skills", ".install-example-skill*").to_s)
        end
      end
    end
  end

  test "install repo-root batches atomically promote all candidates and write per-skill provenance" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Install repo-root batch")
          write_skill!(conversation.agent.workspace_root_path.join("skills"), name: "alpha-skill", description: "Existing alpha skill")

          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill", description: "Replacement alpha skill")
          write_staged_skill!(source_root.join("skills"), name: "beta-skill", description: "Fresh beta skill")

          result =
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )

          assert_equal "repo_root_batch", result.fetch(:mode)
          assert_equal 2, result.fetch(:installed_count)
          assert_equal true, result.fetch(:refresh_effective_on_next_top_level_turn)

          installed_skills = result.fetch(:installed_skills).index_by { |entry| entry.fetch(:installed_name) }
          alpha = installed_skills.fetch("alpha-skill")
          beta = installed_skills.fetch("beta-skill")

          assert_match %r{/.history/skills/alpha-skill/}, alpha.fetch(:snapshot_path)
          assert_nil beta[:snapshot_path]
          assert_includes File.read(Pathname.new(alpha.fetch(:live_path)).join("SKILL.md")), "Replacement alpha skill"
          assert_includes File.read(Pathname.new(beta.fetch(:live_path)).join("SKILL.md")), "Fresh beta skill"

          alpha_provenance = JSON.parse(File.read(alpha.fetch(:provenance_path)))
          beta_provenance = JSON.parse(File.read(beta.fetch(:provenance_path)))

          assert_equal "repo_root_batch", alpha_provenance.fetch("install_mode")
          assert_equal 2, alpha_provenance.fetch("batch_installed_count")
          assert_equal %w[alpha-skill beta-skill], alpha_provenance.fetch("batch_install_names")
          assert_equal "skills/alpha-skill", alpha_provenance.fetch("source_path")
          assert_equal "skills/beta-skill", beta_provenance.fetch("source_path")
        end
      end
    end
  end

  test "repo-root batch install failures roll back every promoted skill" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Repo-root batch rollback")
          existing_root = conversation.agent.workspace_root_path.join("skills", "alpha-skill")
          FileUtils.mkdir_p(existing_root)
          File.write(
            existing_root.join("SKILL.md"),
            <<~MD,
              ---
              name: alpha-skill
              description: Original alpha
              ---

              # alpha-skill
            MD
          )

          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill", description: "Replacement alpha")
          write_staged_skill!(source_root.join("skills"), name: "beta-skill", description: "Fresh beta")

          file_utils = failing_file_utils(fail_on_mv_call: 3)

          assert_raises(RuntimeError) do
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
              file_utils: file_utils,
            )
          end

          assert_includes File.read(existing_root.join("SKILL.md")), "Original alpha"
          refute_predicate conversation.agent.workspace_root_path.join("skills", "beta-skill"), :exist?
          assert_equal [], Dir.glob(conversation.agent.workspace_root_path.join("skills", ".install-*").to_s)
        end
      end
    end
  end

  test "repo-root batch installs support idempotent replace=true reruns" do
    Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
      Dir.mktmpdir("cybros-staged-repo-") do |stage_root|
        with_default_agent_workspace_root(workspace_root) do
          conversation = create_conversation!(title: "Repo-root batch rerun")
          source_root = Pathname.new(stage_root).join("source")
          FileUtils.mkdir_p(source_root)
          write_staged_skill!(source_root.join("skills"), name: "alpha-skill", description: "Alpha description")
          write_staged_skill!(source_root.join("skills"), name: "beta-skill", description: "Beta description")

          first_result =
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )
          second_result =
            Agents::SkillInstallationService.install(
              agent: conversation.agent,
              source_kind: "github",
              repo: "obra/superpowers",
              replace: true,
              source_fetcher: stub_fetcher(stage_root:, skill_root: source_root),
            )

          assert_equal 2, first_result.fetch(:installed_count)
          assert_equal 2, second_result.fetch(:installed_count)
          assert_equal(
            first_result.fetch(:installed_skills).map { |entry| entry.fetch(:installed_name) },
            second_result.fetch(:installed_skills).map { |entry| entry.fetch(:installed_name) },
          )
          assert second_result.fetch(:installed_skills).all? { |entry| entry.fetch(:source_sha256) == entry.fetch(:installed_sha256) }
        end
      end
    end
  end

  private

    def write_skill!(root, name:, description:)
      skill_dir = Pathname.new(root).join(name)
      FileUtils.mkdir_p(skill_dir)
      File.write(
        skill_dir.join("SKILL.md"),
        <<~MD,
          ---
          name: #{name}
          description: #{description}
          ---

          # #{name}
        MD
      )
    end

    def write_staged_skill!(stage_root, name:, description: "Example skill", declared_name: name)
      skill_root = Pathname.new(stage_root).join(name)
      FileUtils.mkdir_p(skill_root.join("references"))
      FileUtils.mkdir_p(skill_root.join("assets"))
      File.write(
        skill_root.join("SKILL.md"),
        <<~MD,
          ---
          name: #{declared_name}
          description: #{description}
          ---

          # #{name}
        MD
      )
      File.write(skill_root.join("references/guide.md"), "guide\n")
      skill_root
    end

    def stub_fetcher(stage_root:, skill_root:)
      Class.new do
        define_method(:fetch!) do |**|
          {
            stage_root: stage_root,
            skill_root: skill_root,
          }
        end
      end.new
    end

    def failing_file_utils(fail_on_mv_call: 2)
      Class.new do
        def initialize(fail_on_mv_call:)
          @mv_calls = 0
          @fail_on_mv_call = fail_on_mv_call
        end

        def cp_r(*args, **kwargs)
          FileUtils.cp_r(*args, **kwargs)
        end

        def mkdir_p(*args, **kwargs)
          FileUtils.mkdir_p(*args, **kwargs)
        end

        def rm_rf(*args, **kwargs)
          FileUtils.rm_rf(*args, **kwargs)
        end

        def mv(*args, **kwargs)
          @mv_calls += 1
          if @mv_calls == @fail_on_mv_call
            raise RuntimeError, "simulated promote failure"
          end

          FileUtils.mv(*args, **kwargs)
        end
      end.new(fail_on_mv_call:)
    end
end
