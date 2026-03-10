# frozen_string_literal: true

require "open3"
require "rbconfig"
require "test_helper"

class TestGemspec < Minitest::Test
  def test_gemspec_loads_without_git_on_path
    script = <<~RUBY
      spec = Gem::Specification.load("simple_inference.gemspec")
      abort "failed to load simple_inference.gemspec" unless spec
      abort "missing library files" unless spec.files.include?("lib/simple_inference.rb")
      abort "gemspec should not be packaged" if spec.files.include?("simple_inference.gemspec")
      puts spec.files.length
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "PATH" => "/nonexistent" },
      RbConfig.ruby,
      "-e",
      script,
      chdir: File.expand_path("..", __dir__)
    )

    message = stderr.empty? ? stdout : stderr
    assert status.success?, "expected gemspec to load without git on PATH, got: #{message}"
    assert_operator stdout.to_i, :>, 0
  end
end
