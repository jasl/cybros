#!/usr/bin/env ruby
require "json"
require "optparse"

unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  ENV["RAILS_ENV"] ||= "development"
  require_relative "../config/environment"
end

module DagDebugCLI
  module_function

  def run(argv)
    command = argv.shift.to_s

    case command
    when "inspect"
      run_inspect(argv)
    when "context"
      run_context(argv)
    when "capture"
      run_capture(argv)
    when "execution"
      run_execution(argv)
    when "retry"
      run_retry(argv)
    when "smoke"
      run_smoke(argv)
    else
      abort usage
    end
  end

  def run_inspect(argv)
    options = parse_common_flags(argv)
    node_id = argv.shift.to_s
    abort usage("inspect requires <node_id>") if node_id.empty?

    result = Cybros::CLI::DAGDebug.inspect_node(node_id)
    emit(result, json: options[:json]) do
      pretty_inspect(result)
    end
  end

  def run_context(argv)
    options = parse_common_flags(argv)
    node_id = argv.shift.to_s
    abort usage("context requires <node_id>") if node_id.empty?

    result = Cybros::CLI::DAGDebug.context_snapshot(node_id)
    emit(result, json: options[:json]) do
      pretty_context(result)
    end
  end

  def run_capture(argv)
    options = { execute: false, retry_first: false, json: false }
    parser =
      OptionParser.new do |opts|
        opts.on("--execute") { options[:execute] = true }
        opts.on("--retry-first") { options[:retry_first] = true }
        opts.on("--json") { options[:json] = true }
      end
    parser.parse!(argv)

    node_id = argv.shift.to_s
    abort usage("capture requires <node_id>") if node_id.empty?

    result =
      Cybros::CLI::DAGDebug.capture_node(
        node_id,
        execute: options[:execute],
        retry_first: options[:retry_first],
      )

    emit(result, json: options[:json]) do
      pretty_capture(result)
    end

    exit_with_result_status(command: "capture", result: result)
  end

  def run_execution(argv)
    options = parse_common_flags(argv)
    node_id = argv.shift.to_s
    abort usage("execution requires <node_id>") if node_id.empty?

    result = Cybros::CLI::DAGDebug.turn_execution_snapshot(node_id)
    emit(result, json: options[:json]) do
      pretty_execution(result)
    end

    exit_with_result_status(command: "execution", result: result)
  end

  def run_retry(argv)
    options = parse_common_flags(argv)
    node_id = argv.shift.to_s
    abort usage("retry requires <node_id>") if node_id.empty?

    result = Cybros::CLI::DAGDebug.retry_node_inline(node_id)
    emit(result, json: options[:json]) do
      pretty_retry(result)
    end

    exit_with_result_status(command: "retry", result: result)
  end

  def run_smoke(argv)
    options = { json: false }
    parser =
      OptionParser.new do |opts|
        opts.on("--conversation-id ID") { |value| options[:conversation_id] = value }
        opts.on("--model-ref REF") { |value| options[:model_ref] = value }
        opts.on("--prompt TEXT") { |value| options[:prompt] = value }
        opts.on("--json") { options[:json] = true }
      end
    parser.parse!(argv)

    abort usage("smoke requires --conversation-id") if options[:conversation_id].to_s.empty?
    abort usage("smoke requires --model-ref") if options[:model_ref].to_s.empty?
    abort usage("smoke requires --prompt") if options[:prompt].to_s.empty?

    result =
      Cybros::CLI::DAGDebug.smoke_conversation_inline(
        conversation_id: options[:conversation_id],
        model_ref: options[:model_ref],
        prompt: options[:prompt],
      )

    emit(result, json: options[:json]) do
      pretty_smoke(result)
    end

    exit_with_result_status(command: "smoke", result: result)
  end

  def parse_common_flags(argv)
    options = { json: false }
    OptionParser.new do |opts|
      opts.on("--json") { options[:json] = true }
    end.parse!(argv)
    options
  end

  def emit(result, json:)
    if json
      puts JSON.pretty_generate(result)
    else
      puts yield
    end
  end

  def exit_with_result_status(command:, result:)
    status = Cybros::CLI::DAGDebug.command_exit_status(command: command, result: result)
    exit(status) if status.nonzero?
  end

  def pretty_inspect(result)
    lines = []
    lines << "Node: #{result.dig("node", "id")} (#{result.dig("node", "node_type")} #{result.dig("node", "state")})"
    if result["conversation"]
      lines << "Conversation: #{result.dig("conversation", "id")} #{result.dig("conversation", "title")}"
    end
    lines << "Retry chain: #{result.fetch("retry_chain").map { |entry| entry.fetch("id") }.join(" -> ")}"
    lines << "Incoming edges: #{result.fetch("incoming_edges").length}"
    result.fetch("incoming_edges").each do |edge|
      lines << "  #{edge.fetch("edge_type")}: #{edge.fetch("from_node_id")} -> #{edge.fetch("to_node_id")}"
    end
    lines << "Outgoing edges: #{result.fetch("outgoing_edges").length}"
    result.fetch("outgoing_edges").each do |edge|
      lines << "  #{edge.fetch("edge_type")}: #{edge.fetch("from_node_id")} -> #{edge.fetch("to_node_id")}"
    end
    lines.join("\n")
  end

  def pretty_context(result)
    lines = []
    lines << "Node: #{result.dig("node", "id")} (#{result.dig("node", "node_type")} #{result.dig("node", "state")})"
    lines << "Context nodes: #{result.fetch("context").length}"
    result.fetch("context").each do |entry|
      lines << "  #{entry.fetch("node_type")} #{entry.fetch("node_id")} #{entry.fetch("state")}"
    end
    lines << "Closure nodes: #{result.fetch("closure").length}"
    lines << "System prompt bytes: #{result.dig("built_prompt", "system_prompt").to_s.bytesize}"
    lines << "Prompt messages: #{result.dig("built_prompt", "messages").length}"
    result.dig("built_prompt", "messages").each_with_index do |message, idx|
      content = message.fetch("content", "")
      preview = content.is_a?(Array) ? content.inspect : content.to_s
      lines << "  [#{idx}] #{message.fetch("role")} #{preview[0, 120]}"
    end
    lines << "Tools: #{Array(result.dig("built_prompt", "tools")).length}"
    lines << "Options: #{result.dig("built_prompt", "options").inspect}"
    lines.join("\n")
  end

  def pretty_capture(result)
    lines = []
    lines << "Source node: #{result.dig("source_node", "id")} (#{result.dig("source_node", "state")})"
    lines << "Target node: #{result.dig("target_node", "id")} (#{result.dig("target_node", "state")})"
    lines << "Execution: #{result.dig("execution", "result_state") || result.dig("execution", "mode")}"
    lines << "Execution error: #{result.dig("execution", "error")}" if result.dig("execution", "error").to_s.present?
    lines << "Execution reason: #{result.dig("execution", "reason")}" if result.dig("execution", "reason").to_s.present?
    if result["context_snapshot"]
      lines << "Context nodes: #{result.dig("context_snapshot", "context").length}"
      lines << "Prompt messages: #{result.dig("context_snapshot", "built_prompt", "messages").length}"
      lines << "Prompt tools: #{Array(result.dig("context_snapshot", "built_prompt", "tools")).length}"
    end
    lines << "Captured provider calls: #{result.fetch("captured_calls").length}"
    result.fetch("captured_calls").each_with_index do |call, idx|
      lines << "  [#{idx}] provider=#{call.fetch("provider_class")} model=#{call.fetch("model")} stream=#{call.fetch("stream")}"
      lines << "      messages=#{call.fetch("messages").length} tools=#{Array(call["tools"]).length}"
      lines << "      options=#{call.fetch("options").inspect}"
    end
    lines << "Wire calls: #{result.fetch("wire_calls").length}"
    result.fetch("wire_calls").each_with_index do |call, idx|
      lines << "  [#{idx}] #{call.fetch("method")}"
      lines << "      #{JSON.pretty_generate(call.fetch("payload"))}"
    end
    lines.join("\n")
  end

  def pretty_execution(result)
    lines = []
    lines << "Turn: #{result.fetch("turn_id")} #{result.fetch("status")}/#{result.fetch("phase")} cursor=#{result.fetch("event_cursor", "(none)")}"
    lines << "Diagnostic level: #{result.fetch("diagnostic_level", "standard")}"
    summary = result.fetch("summary", {})
    if summary.is_a?(Hash)
      lines << "Summary: activities=#{summary.fetch("activity_count", 0)} running=#{summary.fetch("running_count", 0)} waiting=#{summary.fetch("awaiting_count", 0)} failed=#{summary.fetch("failed_count", 0)}"
    end

    lines << "Activities: #{Array(result.fetch("activities", [])).length}"
      Array(result.fetch("activities", [])).each do |activity|
        next unless activity.is_a?(Hash)

        lines << "  [#{activity.fetch("sequence")}] #{activity.fetch("status")} #{activity.fetch("kind")} #{activity.fetch("title")}"
        lines << "      activity_id=#{activity.fetch("activity_id", "(none)")} source_node_id=#{activity.fetch("source_node_id", "(none)")}"
        if activity.dig("error", "summary").to_s.present?
          lines << "      error=#{activity.dig("error", "summary")}"
        end
      if activity.fetch("diagnostics", nil).is_a?(Hash)
        lines << "      diagnostics=#{activity.fetch("diagnostics").inspect}"
      end
    end
    lines.join("\n")
  end

  def pretty_retry(result)
    lines = []
    lines << "Source node: #{result.dig("source_node", "id")} (#{result.dig("source_node", "state")})"
    lines << "Created node: #{result.dig("created_node", "id")} (#{result.dig("created_node", "state")})"
    lines << "ConversationRun: #{result["conversation_run_id"] || "(none)"}"
    lines << "Error: #{result.dig("created_node", "metadata", "error")}"
    lines << "Provider error body: #{result.dig("created_node", "metadata", "provider_error_body").inspect}"
    lines.join("\n")
  end

  def pretty_smoke(result)
    lines = []
    conversation_note =
      if result.dig("conversation", "ephemeral") == true
        " (ephemeral; deleted after run)"
      else
        ""
      end
    lines << "Conversation: #{result.dig("conversation", "id")} #{result.dig("conversation", "title")}#{conversation_note}"
    lines << "User node: #{result.dig("user_node", "id")} (#{result.dig("user_node", "state")})"
    lines << "Agent node: #{result.dig("agent_node", "id")} (#{result.dig("agent_node", "state")})"
    lines << "Agent error: #{result.dig("agent_node", "metadata", "error")}"
    lines << "Provider error body: #{result.dig("agent_node", "metadata", "provider_error_body").inspect}"
    lines << "Agent output: #{result.dig("agent_node", "body_output", "content").to_s[0, 200]}"
    lines.join("\n")
  end

  def usage(error = nil)
    out = +""
    out << "#{error}\n\n" if error
    out << <<~USAGE
      Usage:
        bin/rails runner script/dag_debug.rb inspect <node_id> [--json]
        bin/rails runner script/dag_debug.rb context <node_id> [--json]
        bin/rails runner script/dag_debug.rb capture <node_id> [--execute] [--retry-first] [--json]
        bin/rails runner script/dag_debug.rb execution <node_id> [--json]
        bin/rails runner script/dag_debug.rb retry <node_id> [--json]
        bin/rails runner script/dag_debug.rb smoke --conversation-id <id> --model-ref <ref> --prompt <text> [--json]
    USAGE
    out
  end
end

DagDebugCLI.run(ARGV) unless defined?(Minitest)
