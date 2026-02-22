# frozen_string_literal: true

require "test_helper"

class ValidationErrorCodeEnforcementTest < Minitest::Test
  def test_no_legacy_raise_validation_error_comma_in_production_code
    roots = [
      Rails.root.join("lib/agent_core"),
      Rails.root.join("lib/dag"),
      Rails.root.join("app/models/dag"),
    ]

    ruby_files = roots.flat_map { |root| Dir.glob(root.join("**/*.rb")) }.sort

    pattern = /raise\s+(AgentCore::)?(ConfigurationError|ValidationError)\s*,/
    violations = []

    ruby_files.each do |path|
      content = File.read(path)
      content.each_line.with_index(1) do |line, lineno|
        next unless line.match?(pattern)

        violations << "#{path}:#{lineno}: #{line.strip}"
      end
    end

    assert violations.empty?, "Found legacy raise ValidationError, usage:\n#{violations.join("\n")}"
  end
end
