require "test_helper"
require "stringio"

ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] = "1"
require Rails.root.join("script/live_acceptance/claw_workspace_env_overlay")

class ClawWorkspaceEnvOverlayLiveAcceptanceTest < ActiveSupport::TestCase
  test "runner defines the rbenv shell-resolution scenario and report slug" do
    runner = Cybros::LiveAcceptance::ClawWorkspaceEnvOverlay::Runner.new(io: StringIO.new)

    assert_equal "claw_workspace_env_overlay", runner.report_slug
    assert_equal "rbenv_shell_resolution", runner.scenario_id
    assert_match(/claw-workspace-env-overlay-proof\.md\z/, runner.report_path.to_s)
  end

  test "runner can build lane and root env files for the rbenv scenario" do
    runner = Cybros::LiveAcceptance::ClawWorkspaceEnvOverlay::Runner.new(io: StringIO.new)
    payload =
      runner.send(
        :scenario_payload_for,
        lane_env_path: ".lanes/lane:test/.env.agent",
        root_env_path: "../../.env.agent",
        zsh_probe: {
          "rbenv_root" => "/Users/test/.rbenv",
          "path_value" => "/Users/test/.rbenv/shims:/Users/test/.rbenv/bin:/usr/bin:/bin",
          "ruby_path" => "/Users/test/.rbenv/shims/ruby",
          "ruby_version" => "ruby 3.4.5p1 (2026-01-01 revision abc123) [arm64-darwin25]",
          "bundle_path" => "/Users/test/.rbenv/shims/bundle",
          "bundle_version" => "Bundler version 2.7.1",
        },
        simulated_process_env: {
          "PATH" => "/usr/bin:/bin",
          "BUNDLE_GEMFILE" => "/tmp/poisoned/Gemfile",
          "RUBYOPT" => "-W:deprecated",
        },
      )

    assert_equal "rbenv_shell_resolution", payload.fetch(:scenario_id)
    assert_equal ".lanes/lane:test/.env.agent", payload.fetch(:lane_env_path)
    assert_equal "../../.env.agent", payload.fetch(:root_env_path)
    assert_equal payload.fetch(:lane_env_body), payload.fetch(:root_env_body)
    assert_includes payload.fetch(:lane_env_body), "unset BUNDLE_GEMFILE"
    assert_includes payload.fetch(:lane_env_body), "unset RUBYOPT"
    assert_includes payload.fetch(:lane_env_body), "RBENV_ROOT=/Users/test/.rbenv"
    assert_includes payload.fetch(:lane_env_body), "PATH=/Users/test/.rbenv/shims:/Users/test/.rbenv/bin:/usr/bin:/bin"
    assert_includes payload.fetch(:probe_command), "RUBY_PATH="
    assert_equal "/Users/test/.rbenv/shims/ruby", payload.dig(:expected, "ruby_path")
    assert_equal "/tmp/poisoned/Gemfile", payload.dig(:simulated_process_env, "BUNDLE_GEMFILE")
  end

  test "proof markdown captures the baseline lane and promoted-root verification phases" do
    runner = Cybros::LiveAcceptance::ClawWorkspaceEnvOverlay::Runner.new(io: StringIO.new)
    markdown =
      runner.proof_markdown(
        started_at: Time.utc(2026, 3, 18, 12, 0, 0),
        finished_at: Time.utc(2026, 3, 18, 12, 5, 0),
        model_ref: "openrouter/openai-gpt-5.4",
        environment_label: "development",
        scenario: {
          id: "rbenv_shell_resolution",
          lane_env_path: ".lanes/lane:test/.env.agent",
          root_env_path: "../../.env.agent",
          baseline: { "ruby_path" => "/usr/bin/ruby" },
          lane_fix: { "ruby_path" => "/Users/test/.rbenv/shims/ruby" },
          root_fix: { "ruby_path" => "/Users/test/.rbenv/shims/ruby" },
          expected: { "ruby_path" => "/Users/test/.rbenv/shims/ruby" },
        },
      )

    assert_includes markdown, "# Claw Workspace Env Overlay Proof"
    assert_includes markdown, "Baseline"
    assert_includes markdown, "Lane-local fix"
    assert_includes markdown, "Promoted root fix"
    assert_includes markdown, "Expected interactive zsh target"
    assert_includes markdown, "/Users/test/.rbenv/shims/ruby"
  end
end
