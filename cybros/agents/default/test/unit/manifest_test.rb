require "test_helper"

class ManifestTest < Minitest::Test
  REQUIRED_METHODS = %w[
    initialize
    agent.describe
    agent.health
    agent.schemas.get
    turn.prepare
    turn.compose
    turn.handle_error
  ].freeze

  def test_loads_bundled_manifest_from_source_root
    manifest = Cybros::Agents::Default::Manifest.load!(source_root: TestPaths.source_root)

    assert_equal "default", manifest.fetch("agent_program_key")
    assert_equal "Default", manifest.fetch("name")
    assert_equal "agent_rpc.v1", manifest.fetch("protocol_version")
    assert_equal REQUIRED_METHODS, manifest.fetch("supported_methods")
    assert_equal "noop", manifest.dig("runtime_surface", "type")
    assert_equal "prompts/system.md.liquid", manifest.dig("prompts", "system")
  end
end
