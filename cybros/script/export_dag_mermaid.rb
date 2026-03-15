#!/usr/bin/env ruby
require "fileutils"
require "optparse"
require "pathname"

unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  ENV["RAILS_ENV"] ||= "development"
  require_relative "../config/environment"
end

require_relative "../lib/cybros/cli/dag_mermaid_export"

module DagMermaidExportCLI
  module_function

  def run(argv)
    options = parse_options(argv)
    conversation_id = argv.shift.to_s
    abort usage("export requires <conversation_id>") if conversation_id.empty?

    result =
      Cybros::CLI::DAGMermaidExport.call(
        conversation_id: conversation_id,
        include_compressed: options[:include_compressed],
        max_label_chars: options[:max_label_chars],
      )

    warn format_diagnostics(result.fetch("analysis"))
    emit_mermaid(result.fetch("mermaid"), output_path: options[:output_path])
  end

  def usage(error = nil)
    lines = []
    lines << error if error.present?
    lines << "Usage:"
    lines << "  bin/rails runner script/export_dag_mermaid.rb <conversation_id> [--output PATH] [--include-compressed] [--max-label-chars N]"
    lines << ""
    lines << "Emits Mermaid to stdout by default and diagnostics to stderr."
    lines.join("\n")
  end

  def format_diagnostics(analysis)
    lines = []
    lines << "Exported graph analysis: nodes=#{analysis.fetch("node_count")} edges=#{analysis.fetch("edge_count")} roots=#{analysis.fetch("root_count")} components=#{analysis.fetch("component_count")}"

    if analysis.fetch("root_count") > 1 || analysis.fetch("component_count") > 1
      lines << "Warning: graph has multiple roots or disconnected components; Mermaid will render separate clusters."
      lines << "root_node_ids=#{analysis.fetch("root_node_ids").inspect}"
      lines << "component_sizes=#{analysis.fetch("component_sizes").inspect}"
    end

    lines.join("\n")
  end

  def emit_mermaid(mermaid, output_path:)
    if output_path.to_s.empty?
      puts mermaid
      return
    end

    path = Pathname.new(output_path).expand_path
    FileUtils.mkdir_p(path.dirname)
    File.write(path, mermaid)
    puts path
  end

  def parse_options(argv)
    options = {
      include_compressed: false,
      max_label_chars: 80,
      output_path: nil,
    }

    OptionParser.new do |opts|
      opts.on("--output PATH") { |value| options[:output_path] = value }
      opts.on("--include-compressed") { options[:include_compressed] = true }
      opts.on("--max-label-chars N", Integer) { |value| options[:max_label_chars] = value }
    end.parse!(argv)

    options
  end
end

DagMermaidExportCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
