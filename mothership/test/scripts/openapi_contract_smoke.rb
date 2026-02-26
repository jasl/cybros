#!/usr/bin/env ruby
# Smoke-check that the OpenAPI contract file stays aligned with Rails routes.
#
# This is intentionally lightweight (no OpenAPI validator gem dependency).
#
# Usage:
#   bin/rails runner test/scripts/openapi_contract_smoke.rb

require "yaml"

spec_path = Rails.root.join("..", "docs", "protocol", "conduits_api_openapi.yaml").expand_path
spec = YAML.safe_load(File.read(spec_path), aliases: true)

paths = spec.fetch("paths")

errors = []
routes = Rails.application.routes

paths.each do |path_template, methods|
  methods.each_key do |verb|
    next unless %w[get post put patch delete].include?(verb)

    sample_path = path_template.gsub(/\{[^}]+\}/, "00000000-0000-0000-0000-000000000000")
    begin
      routes.recognize_path(sample_path, method: verb.upcase)
    rescue StandardError => e
      errors << "#{verb.upcase} #{path_template} -> #{e.class}: #{e.message}"
    end
  end
end

if errors.any?
  puts "OpenAPI contract route check FAILED:"
  errors.each { |msg| puts "  - #{msg}" }
  exit 1
end

puts "OpenAPI contract route check OK (#{paths.size} paths)"
