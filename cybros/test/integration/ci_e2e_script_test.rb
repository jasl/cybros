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
end
