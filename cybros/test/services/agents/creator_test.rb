require "test_helper"

class Agents::CreatorTest < ActiveSupport::TestCase
  test "create_from_bundled_source falls back to agent_program_key when agent_key is absent" do
    agent = Agents::Creator.create_from_bundled_source!(name: "Claw bundled", bundled_agent_key: "claw")

    assert_equal "claw", agent.bundled_agent_key
    assert_equal "bundled.claw", agent.config_namespace
    assert_equal "claw", agent.agent_key
    assert_equal "claw", agent.manifest_snapshot.fetch("agent_program_key")
  end
end
