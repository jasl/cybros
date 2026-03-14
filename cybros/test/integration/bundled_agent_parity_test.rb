require "test_helper"

class BundledAgentParityTest < ActiveSupport::TestCase
  test "legacy bundled default implementation is retired and claw is canonical" do
    assert_equal ["claw"], Agents::BundledSources.available_keys
    assert_equal Rails.root.join("agents/claw"), Agents::BundledSources.path_for("claw")
    assert_nil Agents::BundledSources.path_for("default")

    assert_predicate Rails.root.join("agents/claw"), :exist?
    refute_predicate Rails.root.join("agents/default"), :exist?
    refute_predicate Rails.root.join("vendor/agents/claw"), :exist?

    host =
      Cybros::BundledAgentHost::Application.new(
        source_root: Rails.root.join("agents/claw"),
        deployment_fingerprint: "deployment:test-claw",
        required_bearer: "secret://bundled",
      )

    assert_equal "claw", host.identity.fetch("agent_program_key")
    assert_equal "deployment:test-claw", host.identity.fetch("deployment_fingerprint")

    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    assert_equal "claw", agent.bundled_agent_key
    assert_equal Rails.root.join("agents/claw").to_s, agent.absolute_local_path.to_s

    product_doc = Rails.root.join("docs/product/agent_rpc.md").read
    design_doc = Rails.root.join("docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md").read

    assert_includes product_doc, "Current bundled implementation: `claw`"
    assert_includes design_doc, "Implemented result (2026-03-14): canonical bundled implementation is `cybros/agents/claw`"
  end
end
