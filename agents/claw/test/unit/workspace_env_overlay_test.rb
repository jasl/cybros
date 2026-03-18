require "test_helper"
require "tmpdir"
require "fileutils"

class WorkspaceEnvOverlayTest < ActiveSupport::TestCase
  test "merges agent root and current lane env files in order" do
    with_overlay_paths do |root:, lane:|
      write_file(root.join(".env"), <<~ENV)
        PATH=/root/bin
        RBENV_ROOT=/root/.rbenv
      ENV
      write_file(root.join(".env.agent"), <<~ENV)
        PATH=/root-agent/bin
        BUNDLE_GEMFILE=/root/Gemfile
      ENV
      write_file(lane.join(".env"), <<~ENV)
        PATH=/lane/bin
      ENV

      result =
        Cybros::Agents::Claw::WorkspaceEnvOverlay.load(
          process_env: { "PATH" => "/usr/bin", "HOME" => "/home/test" },
          root_path: root,
          lane_path: lane,
        )

      assert_equal "/lane/bin", result.fetch(:env).fetch("PATH")
      assert_equal "/root/.rbenv", result.fetch(:env).fetch("RBENV_ROOT")
      assert_equal "/root/Gemfile", result.fetch(:env).fetch("BUNDLE_GEMFILE")
      assert_equal [
        root.join(".env").to_s,
        root.join(".env.agent").to_s,
        lane.join(".env").to_s,
      ], result.fetch(:loaded_files)
      assert_empty result.fetch(:ignored_files)
      assert_empty result.fetch(:warnings)
    end
  end

  test "supports unset directives" do
    with_overlay_paths do |root:, lane:|
      write_file(root.join(".env.agent"), "unset RUBYOPT\n")
      write_file(lane.join(".env.agent"), "unset BUNDLE_GEMFILE\n")

      result =
        Cybros::Agents::Claw::WorkspaceEnvOverlay.load(
          process_env: {
            "RUBYOPT" => "-rbundler/setup",
            "BUNDLE_GEMFILE" => "/tmp/Gemfile",
            "PATH" => "/usr/bin",
          },
          root_path: root,
          lane_path: lane,
        )

      refute result.fetch(:env).key?("RUBYOPT")
      refute result.fetch(:env).key?("BUNDLE_GEMFILE")
      assert_equal "/usr/bin", result.fetch(:env).fetch("PATH")
    end
  end

  test "ignores malformed files and records warnings" do
    with_overlay_paths do |root:, lane:|
      write_file(root.join(".env"), "PATH=/root/bin\n")
      write_file(lane.join(".env.agent"), "not valid dotenv\n")

      result =
        Cybros::Agents::Claw::WorkspaceEnvOverlay.load(
          process_env: {},
          root_path: root,
          lane_path: lane,
        )

      assert_equal "/root/bin", result.fetch(:env).fetch("PATH")
      assert_equal [root.join(".env").to_s], result.fetch(:loaded_files)
      assert_equal [lane.join(".env.agent").to_s], result.fetch(:ignored_files)
      assert_equal 1, result.fetch(:warnings).length
      assert_includes result.fetch(:warnings).first.fetch(:message), "invalid"
    end
  end

  private

    def with_overlay_paths
      Dir.mktmpdir("claw-overlay-root-") do |dir|
        root = Pathname.new(dir)
        lane = root.join("conversations", "conversation:test", ".lanes", "lane:test")
        lane.mkpath
        yield(root:, lane:)
      end
    end

    def write_file(path, content)
      path.dirname.mkpath
      path.write(content)
    end
end
