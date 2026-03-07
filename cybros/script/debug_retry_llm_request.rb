#!/usr/bin/env ruby
warn "DEPRECATED: use `bin/rails runner script/dag_debug.rb capture <node_id> [--execute] [--retry-first]` instead."

unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  ENV["RAILS_ENV"] ||= "development"
  require_relative "../config/environment"
end

node_id = ARGV[0]&.strip
abort "Usage: bin/rails runner script/debug_retry_llm_request.rb <node_id> [--execute]" if node_id.to_s.empty?

node = DAG::Node.find_by(id: node_id)
forwarded = ["capture", node_id]
if node&.state == DAG::Node::ERRORED && node.node_type == Messages::AgentMessage.node_type_key
  forwarded << "--retry-first"
end
forwarded << "--execute" if ARGV.include?("--execute")
forwarded << "--json" if ARGV.include?("--json")

ARGV.replace(forwarded)
load File.expand_path("dag_debug.rb", __dir__)
