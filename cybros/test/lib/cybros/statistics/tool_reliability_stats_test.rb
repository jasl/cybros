require "test_helper"

class Cybros::Statistics::ToolReliabilityStatsTest < ActiveSupport::TestCase
  setup do
    Statistics::ToolCallFact.delete_all
  end

  teardown do
    Statistics::ToolCallFact.delete_all
  end

  test "aggregates runtime-only reliability metrics and page-ready slices" do
    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_1",
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_2",
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "repaired_args",
      effective_on: Date.new(2026, 3, 8),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_3",
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_scope: "parent",
      execution_readiness: "invalid_args",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_4",
      model_ref: "openai/gpt-5.5",
      provider_key: "openai",
      resolved_name: "missing_tool",
      execution_scope: "parent",
      execution_readiness: "tool_not_found",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_5",
      model_ref: "openai/gpt-5.5",
      provider_key: "openai",
      resolved_name: "write_file",
      execution_scope: "parent",
      execution_readiness: "policy_denied",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_6",
      model_ref: "openai/gpt-5.5",
      provider_key: "openai",
      resolved_name: "write_file",
      execution_scope: "parent",
      execution_readiness: "awaiting_approval",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_7",
      model_ref: "openai/gpt-5.5",
      provider_key: "openai",
      resolved_name: "write_file",
      execution_scope: "parent",
      execution_readiness: "approval_rejected",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_8",
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_scope: "subagent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "failed",
      failure_class: "timeout",
      failure_code: "mcp_timeout",
      retryable: true,
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_fact!(
      task_node_id: uuidv7,
      tool_call_id: "tc_9",
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "repaired_args",
      manual_retry: true,
      effective_on: Date.new(2026, 3, 9),
    )

    create_fact!(
      task_node_id: uuidv7,
      sample_origin: "debug",
      tool_call_id: "tc_debug",
      model_ref: "debug/mock-model",
      provider_key: "dev",
      resolved_name: "debug_tool",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    stats = Cybros::Statistics::ToolReliabilityStats.snapshot
    summary = stats.fetch("summary")

    assert_equal 9, summary.fetch("total_calls")
    assert_equal 8, summary.fetch("model_attempts")
    assert_equal 4, summary.fetch("tool_executions")

    assert_rate summary.fetch("executable_rate"), count: 3, total: 8, value: 0.375
    assert_rate summary.fetch("first_pass_success_rate"), count: 1, total: 8, value: 0.125
    assert_rate summary.fetch("repair_assisted_success_rate"), count: 1, total: 8, value: 0.125
    assert_rate summary.fetch("tool_success_rate"), count: 3, total: 4, value: 0.75

    assert_equal 2, summary.dig("model_failures", "total")
    assert_equal 1, summary.dig("model_failures", "invalid_args")
    assert_equal 1, summary.dig("model_failures", "tool_not_found")

    assert_equal 1, summary.dig("side_outcomes", "policy_denied")
    assert_equal 1, summary.dig("side_outcomes", "awaiting_approval")
    assert_equal 1, summary.dig("side_outcomes", "approval_rejected")

    by_model = stats.fetch("by_model_ref")
    gpt_54 = by_model.find { |row| row.fetch("model_ref") == "openai/gpt-5.4" }
    gpt_55 = by_model.find { |row| row.fetch("model_ref") == "openai/gpt-5.5" }

    assert_equal 5, gpt_54.fetch("total_calls")
    assert_equal 4, gpt_54.fetch("model_attempts")
    assert_rate gpt_54.fetch("tool_success_rate"), count: 3, total: 4, value: 0.75
    assert_equal 1, gpt_54.dig("model_failures", "invalid_args")

    assert_equal 4, gpt_55.fetch("total_calls")
    assert_equal 4, gpt_55.fetch("model_attempts")
    assert_equal 1, gpt_55.dig("model_failures", "tool_not_found")
    assert_equal 1, gpt_55.dig("side_outcomes", "policy_denied")

    by_tool = stats.fetch("by_tool_name")
    shell = by_tool.find { |row| row.fetch("resolved_name") == "shell_exec" }
    write = by_tool.find { |row| row.fetch("resolved_name") == "write_file" }

    assert_equal 5, shell.fetch("total_calls")
    assert_equal 4, shell.fetch("tool_executions")
    assert_rate shell.fetch("repair_assisted_success_rate"), count: 1, total: 4, value: 0.25

    assert_equal 3, write.fetch("total_calls")
    assert_equal 0, write.fetch("tool_executions")
    assert_equal 1, write.dig("side_outcomes", "policy_denied")

    by_failure = stats.fetch("by_failure_class")
    timeout = by_failure.find { |row| row.fetch("failure_class") == "timeout" }

    assert_equal 1, timeout.fetch("count")

    by_day = stats.fetch("by_day")
    day_1 = by_day.find { |row| row.fetch("date") == "2026-03-08" }
    day_2 = by_day.find { |row| row.fetch("date") == "2026-03-09" }

    assert_equal 4, day_1.fetch("total_calls")
    assert_rate day_1.fetch("tool_success_rate"), count: 2, total: 2, value: 1.0

    assert_equal 5, day_2.fetch("total_calls")
    assert_rate day_2.fetch("tool_success_rate"), count: 1, total: 2, value: 0.5

    by_scope = stats.fetch("by_execution_scope")
    parent = by_scope.find { |row| row.fetch("execution_scope") == "parent" }
    subagent = by_scope.find { |row| row.fetch("execution_scope") == "subagent" }

    assert_equal 8, parent.fetch("total_calls")
    assert_equal 7, parent.fetch("model_attempts")
    assert_rate parent.fetch("tool_success_rate"), count: 3, total: 3, value: 1.0

    assert_equal 1, subagent.fetch("total_calls")
    assert_equal 1, subagent.fetch("model_attempts")
    assert_rate subagent.fetch("tool_success_rate"), count: 0, total: 1, value: 0.0
  end

  test "groups reliability slices by programmable runtime routing dimensions" do
    program_id = uuidv7

    create_fact!(
      task_node_id: uuidv7,
      logical_tool_name: "compact_context",
      resolved_name: "compact_context",
      implementation_source: "agent_program",
      implementation_ref: "agent://compact_context",
      capability_registry_snapshot_id: "cap_snapshot_123",
      kernel_capability_registry_version: "kernel:v1",
      tool_surface_id: "tool_surface_123",
      tool_surface_label: "bundled_default.before_agent_step",
      agent_program_id: program_id,
      agent_program_version: "default-agent-capabilities:v1",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      duration_ms: 42,
      effective_on: Date.new(2026, 3, 10),
    )

    create_fact!(
      task_node_id: uuidv7,
      logical_tool_name: "compact_context",
      resolved_name: "compact_context",
      implementation_source: "kernel",
      implementation_ref: "kernel://compact_context",
      capability_registry_snapshot_id: "cap_snapshot_123",
      kernel_capability_registry_version: "kernel:v1",
      tool_surface_id: "tool_surface_123",
      tool_surface_label: "bundled_default.before_agent_step",
      agent_program_id: program_id,
      agent_program_version: "default-agent-capabilities:v1",
      execution_scope: "parent",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "failed",
      failure_class: "implementation_error",
      model_attempt_class: "first_pass",
      duration_ms: 84,
      effective_on: Date.new(2026, 3, 10),
    )

    stats = Cybros::Statistics::ToolReliabilityStats.snapshot

    by_logical_tool = stats.fetch("by_logical_tool_name")
    by_implementation_source = stats.fetch("by_implementation_source")
    by_tool_surface = stats.fetch("by_tool_surface_id")
    by_agent_program_id = stats.fetch("by_agent_program_id")
    by_agent_program_version = stats.fetch("by_agent_program_version")

    summary = stats.fetch("summary")
    compact_context = by_logical_tool.find { |row| row.fetch("logical_tool_name") == "compact_context" }
    agent_program = by_implementation_source.find { |row| row.fetch("implementation_source") == "agent_program" }
    kernel = by_implementation_source.find { |row| row.fetch("implementation_source") == "kernel" }
    tool_surface = by_tool_surface.find { |row| row.fetch("tool_surface_id") == "tool_surface_123" }
    agent_program_id_row = by_agent_program_id.find { |row| row.fetch("agent_program_id") == program_id }
    agent_version = by_agent_program_version.find { |row| row.fetch("agent_program_version") == "default-agent-capabilities:v1" }

    assert_equal 2, summary.dig("result_status", "total")
    assert_equal 1, summary.dig("result_status", "success")
    assert_equal 1, summary.dig("result_status", "failed")
    assert_equal 0, summary.dig("result_status", "not_executed")
    assert_equal 2, summary.dig("latency_ms", "count")
    assert_equal 63, summary.dig("latency_ms", "avg")
    assert_equal 84, summary.dig("latency_ms", "max")
    assert_equal 2, compact_context.fetch("total_calls")
    assert_equal 1, agent_program.fetch("total_calls")
    assert_equal 1, kernel.fetch("total_calls")
    assert_equal 2, tool_surface.fetch("total_calls")
    assert_equal 2, agent_program_id_row.fetch("total_calls")
    assert_equal 2, agent_version.fetch("total_calls")
  end

  private

    def create_fact!(overrides = {})
      Statistics::ToolCallFact.create!(
        {
          task_node_id: uuidv7,
          retry_of_task_node_id: nil,
          conversation_id: uuidv7,
          root_conversation_id: uuidv7,
          user_id: uuidv7,
          graph_id: uuidv7,
          turn_id: uuidv7,
          sample_origin: "runtime",
          execution_scope: "parent",
          tool_call_id: "tc_default",
          requested_name: "shell_exec",
          resolved_name: "shell_exec",
          name_resolution: "exact",
          arguments_resolution: "original",
          model_attempt_class: "first_pass",
          source: "shell",
          provider_key: "openai",
          model_ref: "openai/gpt-5.4",
          execution_readiness: "executable",
          entered_execution: false,
          tool_outcome: "not_executed",
          failure_class: nil,
          failure_code: nil,
          retryable: nil,
          manual_retry: false,
          effective_on: Date.new(2026, 3, 8),
        }.merge(overrides)
      )
    end

    def assert_rate(actual, count:, total:, value:)
      assert_equal count, actual.fetch("count")
      assert_equal total, actual.fetch("total")
      assert_in_delta value, actual.fetch("value"), 1e-9
    end

    def uuidv7
      ActiveRecord::Base.with_connection do |connection|
        connection.select_value("select uuidv7()")
      end
    end
end
