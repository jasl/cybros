require "test_helper"

class Agents::BootstrapBundledDefaultServiceTest < ActiveSupport::TestCase
  test "bootstrap delegates to ensure_agent" do
    service = Agents::BootstrapBundledDefaultService.new
    service.define_singleton_method(:ensure_agent!) { :bootstrapped_agent }

    assert_equal :bootstrapped_agent, service.bootstrap!
  end

  test "ensure_agent provisions the claw bundled source as the managed local default" do
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    assert_equal "claw", agent.bundled_agent_key
    assert_equal "bundled", agent.source_kind
    assert_equal Rails.root.join("agents/claw").to_s, agent.absolute_local_path.to_s
    assert_equal "http_jsonrpc", agent.transport_kind
    assert_equal "deployment:bundled-claw:test", agent.deployment_fingerprint if Rails.env.test?
  end
end
