require "test_helper"

class CiScriptTest < ActiveSupport::TestCase
  test "config ci runs bundled claw verification" do
    config = Rails.root.join("config/ci.rb").read

    assert_includes config, 'step "Tests: Bundled claw runtime"'
    assert_includes config, "test/integration/bundled_agent_parity_test.rb"
    assert_includes config, "test/integration/agent_runtime_binding_cutover_test.rb"
    assert_includes config, "test/services/agents/bootstrap_bundled_default_service_test.rb"
  end
end
