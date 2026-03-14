require_relative "../test_helper"

class ManifestTest < Minitest::Test
  REQUIRED_METHODS = %w[
    initialize
    agent.describe
    agent.health
    agent.schemas.get
    capabilities.handshake
    capabilities.refresh
    attachments.import
    on_conversation_created
    on_lane_first_user_message
    before_agent_step
    on_context_pressure
    before_subagent_spawn
    before_finalize_output
    after_task_notice
    after_subagent_result
  ].freeze

  def test_loads_bundled_manifest_from_source_root
    manifest = Cybros::Agents::Default::Manifest.load!(source_root: TestPaths.source_root)

    assert_equal "default", manifest.fetch("agent_program_key")
    assert_equal "Default", manifest.fetch("name")
    assert_equal "agent_rpc.v1", manifest.fetch("protocol_version")
    assert_equal REQUIRED_METHODS, manifest.fetch("supported_methods")
    refute manifest.key?("runtime_surface")
    assert_equal "prompts/system.md.liquid", manifest.dig("prompts", "system")
  end
end
