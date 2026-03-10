require "test_helper"

class AgentProgramsTest < ActiveSupport::TestCase
  test "bundled source registry exposes the default bundled agent" do
    assert_includes AgentPrograms::BundledSources.available_keys, "default"
    assert_equal Rails.root.join("agents", "default"), AgentPrograms::BundledSources.path_for("default")
  end

  test "creator builds a bundled default agent program from the bundled source registry" do
    program = AgentPrograms::Creator.create_from_bundled_source!(name: "Default assistant", bundled_agent_key: "default")

    assert_equal "bundled", program.source_kind
    assert_equal "default", program.bundled_agent_key
    assert_equal "agents/default", program.local_path
    assert_equal "default", program.manifest_snapshot.fetch("agent_program_key")
    assert_equal true, program.absolute_local_path.directory?
  end
end
