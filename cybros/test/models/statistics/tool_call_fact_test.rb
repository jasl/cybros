require "test_helper"

class Statistics::ToolCallFactTest < ActiveSupport::TestCase
  test "validates task_node_id uniqueness" do
    task_node_id = uuidv7

    Statistics::ToolCallFact.create!(valid_attributes(task_node_id: task_node_id))
    duplicate = Statistics::ToolCallFact.new(valid_attributes(task_node_id: task_node_id))

    refute duplicate.valid?
    assert duplicate.errors.added?(:task_node_id, :taken) || duplicate.errors[:task_node_id].any?
  end

  test "accepts only the frozen runtime enum values" do
    refute Statistics::ToolCallFact.new(valid_attributes(sample_origin: "staging")).valid?
    refute Statistics::ToolCallFact.new(valid_attributes(execution_scope: "child")).valid?
    refute Statistics::ToolCallFact.new(valid_attributes(model_attempt_class: "manual_retry")).valid?
    refute Statistics::ToolCallFact.new(valid_attributes(execution_readiness: "queued")).valid?
    refute Statistics::ToolCallFact.new(valid_attributes(tool_outcome: "partial")).valid?

    assert_equal %w[runtime eval debug replay], Statistics::ToolCallFact::SAMPLE_ORIGINS
    assert_equal %w[parent subagent], Statistics::ToolCallFact::EXECUTION_SCOPES
    assert_equal %w[first_pass repaired_name repaired_args repaired_both], Statistics::ToolCallFact::MODEL_ATTEMPT_CLASSES
    assert_equal %w[executable invalid_args tool_not_found policy_denied awaiting_approval approval_rejected], Statistics::ToolCallFact::EXECUTION_READINESS_VALUES
    assert_equal %w[success failed not_executed], Statistics::ToolCallFact::TOOL_OUTCOMES
  end

  test "defaults entered_execution and manual_retry to false" do
    fact = Statistics::ToolCallFact.create!(valid_attributes)

    assert_equal false, fact.entered_execution
    assert_equal false, fact.manual_retry
  end

  test "stores correlation ids, tool identifiers, timing, and failure metadata" do
    started_at = Time.zone.parse("2026-03-08 10:00:01 UTC")
    finished_at = Time.zone.parse("2026-03-08 10:00:02 UTC")

    fact =
      Statistics::ToolCallFact.create!(
        valid_attributes(
          retry_of_task_node_id: uuidv7,
          tool_call_id: "tc_1",
          requested_name: "skills.list",
          resolved_name: "skills_list",
          name_resolution: "alias",
          arguments_resolution: "original",
          source: "skills",
          provider_key: "openai",
          model_ref: "openai/gpt-5.4",
          entered_execution: true,
          tool_outcome: "failed",
          failure_class: "remote_api_error",
          failure_code: "mcp_transport_error",
          retryable: true,
          started_at: started_at,
          finished_at: finished_at,
          effective_on: Date.new(2026, 3, 8),
          duration_ms: 912,
        )
      )

    fact.reload
    assert_equal "tc_1", fact.tool_call_id
    assert_equal "skills.list", fact.requested_name
    assert_equal "skills_list", fact.resolved_name
    assert_equal "alias", fact.name_resolution
    assert_equal "original", fact.arguments_resolution
    assert_equal "skills", fact.source
    assert_equal "openai", fact.provider_key
    assert_equal "openai/gpt-5.4", fact.model_ref
    assert_equal true, fact.entered_execution
    assert_equal "failed", fact.tool_outcome
    assert_equal "remote_api_error", fact.failure_class
    assert_equal "mcp_transport_error", fact.failure_code
    assert_equal true, fact.retryable
    assert_equal started_at.to_i, fact.started_at.to_i
    assert_equal finished_at.to_i, fact.finished_at.to_i
    assert_equal Date.new(2026, 3, 8), fact.effective_on
    assert_equal 912, fact.duration_ms
  end

  test "stores programmable runtime routing and capability dimensions" do
    fact =
      Statistics::ToolCallFact.create!(
        valid_attributes(
          logical_tool_name: "compact_context",
          capability_registry_snapshot_id: "cap_snapshot_123",
          kernel_capability_registry_version: "kernel:v1",
          tool_surface_id: "tool_surface_123",
          tool_surface_label: "bundled_default.before_agent_step",
          implementation_source: "agent_program",
          implementation_ref: "agent://compact_context",
          agent_program_id: uuidv7,
          agent_program_version: "default-agent-capabilities:v1",
        )
      )

    fact.reload
    assert_equal "compact_context", fact.logical_tool_name
    assert_equal "cap_snapshot_123", fact.capability_registry_snapshot_id
    assert_equal "kernel:v1", fact.kernel_capability_registry_version
    assert_equal "tool_surface_123", fact.tool_surface_id
    assert_equal "bundled_default.before_agent_step", fact.tool_surface_label
    assert_equal "agent_program", fact.implementation_source
    assert_equal "agent://compact_context", fact.implementation_ref
    assert fact.agent_program_id.present?
    assert_equal "default-agent-capabilities:v1", fact.agent_program_version
  end

  private

    def valid_attributes(overrides = {})
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
        requested_name: "skills.list",
        resolved_name: "skills_list",
        name_resolution: "alias",
        arguments_resolution: "original",
        model_attempt_class: "first_pass",
        source: "skills",
        provider_key: "openai",
        model_ref: "openai/gpt-5.4",
        execution_readiness: "executable",
        tool_outcome: "success",
        failure_class: nil,
        failure_code: nil,
        retryable: nil,
        effective_on: Date.new(2026, 3, 8),
        duration_ms: nil,
      }.merge(overrides)
    end

    def uuidv7
      ActiveRecord::Base.connection.select_value("select uuidv7()")
    end
end
