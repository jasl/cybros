# frozen_string_literal: true

require "test_helper"

class AgentCoreDependencyEnforcementTest < Minitest::Test
  def test_agent_core_does_not_reference_app_namespaces
    root = Rails.root.join("lib/agent_core")
    ruby_files = Dir.glob(root.join("**/*.rb")).sort

    patterns = {
      "Cybros::" => /\bCybros::/,
      "Messages::" => /\bMessages::/,
      "Rails.root" => /\bRails\.root\b/,
    }

    violations = []

    ruby_files.each do |path|
      content = File.read(path)
      patterns.each do |label, regex|
        content.each_line.with_index(1) do |line, lineno|
          next unless line.match?(regex)

          violations << "#{path}:#{lineno}: #{label}: #{line.strip}"
        end
      end
    end

    assert violations.empty?, "Found app-coupled references in AgentCore:\n#{violations.join("\n")}"
  end
end
