# frozen_string_literal: true

require_relative "lib/simple_inference/version"

Gem::Specification.new do |spec|
  spec.name = "simple_inference"
  spec.version = SimpleInference::VERSION
  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "A lightweight, Fiber-friendly Ruby client for OpenAI-compatible LLM APIs."
  spec.description =
    "A lightweight, Fiber-friendly Ruby client for OpenAI-compatible LLM APIs. (chat, embeddings, audio, rerank, health)."
  spec.homepage = "https://github.com/jasl/simple_inference.rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.start_with?(
        *%w[Gemfile bin test docs tmp]
      ) ||
      (f.end_with?(".md") &&
        !%w[README.md].include?(f)
      )
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
