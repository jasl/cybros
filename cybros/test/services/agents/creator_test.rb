require "test_helper"

class Agents::CreatorTest < ActiveSupport::TestCase
  test "create_from_bundled_source snapshots agent_key from the bundled manifest" do
    agent = Agents::Creator.create_from_bundled_source!(name: "Claw bundled", bundled_agent_key: "claw")

    assert_equal "claw", agent.bundled_agent_key
    assert_equal "bundled.claw", agent.config_namespace
    assert_equal "claw", agent.agent_key
    assert_equal "claw", agent.manifest_snapshot.fetch("agent_key")
    refute agent.manifest_snapshot.key?("agent_program_key")
  end

  test "create_from_bundled_source rejects manifests that only expose agent_program_key" do
    with_temp_bundled_manifest(
      {
        "agent_program_key" => "legacy-claw",
        "name" => "Legacy Claw",
        "description" => "Legacy bundled claw manifest",
        "config_namespace" => "bundled.legacy-claw",
        "protocol_version" => "agent_rpc.v1",
        "agent_sdk_version" => "cybros-bundled-claw/1.0",
        "supported_methods" => %w[initialize agent.describe agent.health agent.schemas.get],
        "global_config_schema" => { "type" => "object", "properties" => {} },
        "conversation_config_schema" => { "type" => "object", "properties" => {} },
        "prompts" => {},
      },
    ) do
      error =
        assert_raises(KeyError) do
          Agents::Creator.create_from_bundled_source!(name: "Legacy Claw", bundled_agent_key: "legacy")
        end

      assert_includes error.message, "agent_key"
    end
  end

  private

    def with_temp_bundled_manifest(manifest)
      Dir.mktmpdir("cybros-bundled-manifest-") do |source_root|
        File.write(File.join(source_root, "agent.yml"), YAML.dump(manifest))

        original_path_for = Agents::BundledSources.method(:path_for)
        original_relative_path_for = Agents::BundledSources.method(:relative_path_for)

        Agents::BundledSources.define_singleton_method(:path_for) do |key|
          key.to_s == "legacy" ? Pathname.new(source_root) : original_path_for.call(key)
        end
        Agents::BundledSources.define_singleton_method(:relative_path_for) do |key|
          key.to_s == "legacy" ? "tmp/legacy" : original_relative_path_for.call(key)
        end

        yield
      ensure
        Agents::BundledSources.define_singleton_method(:path_for, original_path_for)
        Agents::BundledSources.define_singleton_method(:relative_path_for, original_relative_path_for)
      end
    end
end
