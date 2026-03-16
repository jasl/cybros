require "test_helper"
require "open3"
require "timeout"

class CiE2EScriptTest < ActiveSupport::TestCase
  test "bin/ci_e2e rejects non-development rails env" do
    script = Rails.root.join("bin/ci_e2e")

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "RAILS_ENV" => "test",
            "E2E_PORT" => "3910",
          },
          script.to_s,
          "--help",
          chdir: Rails.root.to_s,
        )
    end

    refute_predicate status, :success?
    output = [stdout, stderr].join("\n")
    assert_includes output, "bin/ci_e2e must run with RAILS_ENV=development"
  end

  test "bin/ci_e2e can boot the programmable-agent fixture in dry-run mode" do
    script = Rails.root.join("bin/ci_e2e")

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "RAILS_ENV" => "development",
            "CI_E2E_DRY_RUN" => "1",
            "CI_E2E_BOOT_BUNDLED_CLAW" => "0",
            "CI_E2E_PROGRAMMABLE_AGENT_FIXTURE" => "1",
            "PROGRAMMABLE_AGENT_FIXTURE_PORT" => "3912",
            "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => nil,
            "CYBROS_BUNDLED_CLAW_PORT" => nil,
          },
          script.to_s,
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?
    output = [stdout, stderr].join("\n")
    assert_includes output, "bundled claw rpc url: http://127.0.0.1:4242/rpc"
    assert_includes output, "programmable agent fixture enabled"
    assert_includes output, "http://127.0.0.1:3912/rpc"
    assert_includes output, "CI E2E dry run complete"
  end

  test "bin/ci_e2e auto-enables the programmable-agent fixture for programmable-agent specs" do
    script = Rails.root.join("bin/ci_e2e")

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "RAILS_ENV" => "development",
            "CI_E2E_DRY_RUN" => "1",
            "CI_E2E_BOOT_BUNDLED_CLAW" => "0",
            "PROGRAMMABLE_AGENT_FIXTURE_PORT" => "3913",
            "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => nil,
            "CYBROS_BUNDLED_CLAW_PORT" => nil,
          },
          script.to_s,
          "test/e2e/programmable_agent_registration.spec.ts",
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?
    output = [stdout, stderr].join("\n")
    assert_includes output, "bundled claw rpc url: http://127.0.0.1:4242/rpc"
    assert_includes output, "programmable agent fixture enabled"
    assert_includes output, "http://127.0.0.1:3913/rpc"
    assert_includes output, "CI E2E dry run complete"
  end
end
