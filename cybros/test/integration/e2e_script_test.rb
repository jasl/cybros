require "test_helper"
require "open3"
require "timeout"

class E2EScriptTest < ActiveSupport::TestCase
  test "bin/e2e auto-starts the programmable-agent fixture for programmable-agent specs in dry-run mode" do
    script = Rails.root.join("bin/e2e")

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "E2E_DRY_RUN" => "1",
            "PROGRAMMABLE_AGENT_FIXTURE_PORT" => "3914",
            "PROGRAMMABLE_AGENT_FIXTURE_URL" => nil,
          },
          script.to_s,
          "test/e2e/programmable_agent_approval_resume.spec.ts",
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?
    output = [stdout, stderr].join("\n")
    assert_includes output, "programmable agent fixture enabled"
    assert_includes output, "http://127.0.0.1:3914/rpc"
    assert_includes output, "E2E dry run complete"
  end

  test "bin/e2e skips the programmable-agent fixture for non-programmable specs in dry-run mode" do
    script = Rails.root.join("bin/e2e")

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(20) do
      stdout, stderr, status =
        Open3.capture3(
          {
            "E2E_DRY_RUN" => "1",
            "PROGRAMMABLE_AGENT_FIXTURE_PORT" => "3915",
            "PROGRAMMABLE_AGENT_FIXTURE_URL" => nil,
          },
          script.to_s,
          "test/e2e/auth.spec.ts",
          chdir: Rails.root.to_s,
        )
    end

    assert_predicate status, :success?
    output = [stdout, stderr].join("\n")
    refute_includes output, "programmable agent fixture enabled"
    assert_includes output, "E2E dry run complete"
  end
end
