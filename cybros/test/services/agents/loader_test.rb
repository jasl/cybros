require "test_helper"
require "tmpdir"

class Agents::LoaderTest < ActiveSupport::TestCase
  test "load treats malformed yaml as a missing manifest instead of raising" do
    Dir.mktmpdir("agents-loader") do |dir|
      File.write(File.join(dir, "agent.yml"), "{invalid")

      loaded = Agents::Loader.new(base_dir: dir).load

      assert_equal({}, loaded.manifest)
      assert_equal "missing", loaded.runtime_surface_status
      assert_equal Cybros::AgentProfileConfig.default_runtime_surface_metadata, loaded.runtime_surface_config
    end
  end

  test "load marks unsupported runtime surface payloads as invalid" do
    Dir.mktmpdir("agents-loader") do |dir|
      File.write(
        File.join(dir, "agent.yml"),
        <<~YAML,
          runtime_surface:
            type: nope
        YAML
      )

      loaded = Agents::Loader.new(base_dir: dir).load

      assert_equal "invalid", loaded.runtime_surface_status
      assert_equal Cybros::AgentProfileConfig.default_runtime_surface_metadata, loaded.runtime_surface_config
      assert_equal({ "runtime_surface" => { "type" => "nope" } }, loaded.manifest)
    end
  end

  test "load falls back cleanly when the loader times out" do
    loader_class =
      Class.new(Agents::Loader) do
        private

          def safe_yaml(_rel)
            sleep 0.05
            {}
          end
      end

    loaded = loader_class.new(base_dir: Dir.tmpdir, timeout_s: 0.01).load

    assert_equal({}, loaded.manifest)
    assert_equal "missing", loaded.runtime_surface_status
    assert_equal Cybros::AgentProfileConfig.default_runtime_surface_metadata, loaded.runtime_surface_config
  end
end
