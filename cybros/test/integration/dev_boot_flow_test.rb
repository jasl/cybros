require "test_helper"

class DevBootFlowTest < ActiveSupport::TestCase
  test "Procfile.dev boots a dedicated bundled claw process with explicit bootstrap env" do
    procfile = Rails.root.join("Procfile.dev").read

    assert_includes procfile, "claw:"
    assert_includes procfile, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL="
    assert_includes procfile, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER="
    assert_includes procfile, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT="
    assert_includes procfile, "CLAW_REQUIRED_BEARER="
    assert_includes procfile, "CLAW_DEPLOYMENT_FINGERPRINT="
    assert_includes procfile, "CLAW_WORKSPACE_ROOT="
    assert_includes procfile, "cd ../agents/claw &&"
    assert_includes procfile, "BUNDLE_GEMFILE=$PWD/Gemfile"
    assert_includes procfile, "CLAW_WORKSPACE_ROOT=$OLDPWD/tmp/agent-workspace/bundled/claw"
    assert_includes procfile, "../agents/claw"
    refute_includes procfile, "fixture:"
    refute_includes procfile, "PROGRAMMABLE_AGENT_FIXTURE_URL="
    refute_includes procfile, "bin/programmable_agent_fixture"
  end

  test "bin/dev propagates bundled claw bootstrap env defaults to the managed stack" do
    script = Rails.root.join("bin/dev").read

    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL"
    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER"
    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT"
    refute_includes script, "PROGRAMMABLE_AGENT_FIXTURE_HOST"
    refute_includes script, "PROGRAMMABLE_AGENT_FIXTURE_PORT"
    refute_includes script, "PROGRAMMABLE_AGENT_FIXTURE_URL"
  end

  test "bin/e2e exports bundled claw bootstrap env defaults and can manage a programmable fixture" do
    script = Rails.root.join("bin/e2e").read

    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL"
    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER"
    assert_includes script, "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT"
    assert_includes script, "CYBROS_BUNDLED_CLAW_PORT"
    assert_includes script, "PROGRAMMABLE_AGENT_FIXTURE_HOST"
    assert_includes script, "PROGRAMMABLE_AGENT_FIXTURE_PORT"
    assert_includes script, "PROGRAMMABLE_AGENT_FIXTURE_URL"
    assert_includes script, "bin/programmable_agent_fixture"
    assert_includes script, "E2E_DRY_RUN"
  end
end
