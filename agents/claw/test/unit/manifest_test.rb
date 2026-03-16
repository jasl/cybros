require_relative "../test_helper"

class ManifestTest < ActiveSupport::TestCase
  test "loads bundled manifest from source root" do
    manifest = Cybros::Agents::Claw::Manifest.load!(source_root: TestPaths.source_root)

    assert_manifest_contract(
      manifest,
      expected_agent_program_key: "claw",
      expected_name: "Claw",
      expected_description: "Bundled claw Cybros programmable agent.",
      expected_config_namespace: "bundled.claw",
      expected_agent_sdk_version: "cybros-bundled-claw/1.0"
    )
  end
end
