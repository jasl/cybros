require "test_helper"

class LegacyLlmProviderNameEnforcementTest < Minitest::Test
  def test_no_legacy_llm_provider_constant_name_in_repo
    roots = %w[app db test docs].map { |entry| Rails.root.join(entry) }
    legacy_name = "LLM" + "Provider"
    pattern = /\b#{Regexp.escape(legacy_name)}\b/
    violations = []

    roots.each do |root|
      Dir.glob(root.join("**/*")).sort.each do |path|
        next unless File.file?(path)

        File.read(path).each_line.with_index(1) do |line, lineno|
          next unless line.match?(pattern)

          violations << "#{path}:#{lineno}: #{line.strip}"
        end
      end
    end

    assert violations.empty?, "Found legacy provider constant name:\n#{violations.join("\n")}"
  end
end
