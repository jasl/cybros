require "test_helper"

class BundledAgentParityTest < ActiveSupport::TestCase
  test "legacy bundled default implementation is retired and claw is canonical" do
    source_root = Agents::BundledSources.path_for("claw")

    assert_equal ["claw"], Agents::BundledSources.available_keys
    assert_equal Rails.root.parent.join("agents/claw"), source_root
    assert_nil Agents::BundledSources.path_for("default")

    assert_predicate source_root, :exist?
    refute_predicate Rails.root.parent.join("agents/default"), :exist?
    refute_predicate Rails.root.join("vendor/agents/claw"), :exist?

    server =
      TestSupport::BundledClawRuntimeServer.new(
        source_root: source_root,
        deployment_fingerprint: "deployment:test-claw",
        required_bearer: "secret://bundled",
      ).start

    with_env(
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => server.rpc_url,
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER" => "secret://bundled",
      "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT" => "deployment:test-claw",
    ) do
      agent = Agents::BootstrapBundledDefaultService.ensure_agent!
      assert_equal "claw", agent.bundled_agent_key
      assert_equal source_root.to_s, agent.absolute_local_path.to_s
      assert_equal server.rpc_url, agent.endpoint_url
    end

    product_doc = Rails.root.join("docs/product/agent_rpc.md").read
    readme_doc = Rails.root.join("docs/product/README.md").read
    vision_doc = Rails.root.join("docs/product/vision.md").read
    design_doc = Rails.root.join("docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md").read

    assert_includes product_doc, "Current bundled implementation: `claw`"
    assert_includes design_doc, "Implemented result (2026-03-14): canonical bundled implementation is `agents/claw`"
    assert_includes readme_doc, "Each `Agent` owns one durable root workspace"
    assert_not_includes readme_doc, "Each conversation owns one persistent logical workspace that is lazy-initialized."
    assert_includes vision_doc, "The bundled/default agent path now uses an agent-owned root workspace"
    assert_not_includes vision_doc, "Conversation-owned logical workspaces are persistent and lazy-initialized instead of being exposed as standalone product inventory."
  ensure
    server&.shutdown
  end

  private

    def with_env(values)
      original = values.to_h { |key, _value| [key, ENV[key]] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      original.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
end
