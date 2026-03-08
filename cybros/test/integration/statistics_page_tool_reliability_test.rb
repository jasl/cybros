require "test_helper"

class StatisticsPageToolReliabilityTest < ActionDispatch::IntegrationTest
  setup do
    Statistics::ToolCallFact.delete_all
  end

  test "statistics page shows runtime tool reliability sections and excludes non-runtime facts" do
    sign_in!(email: "owner@example.com")

    create_tool_fact!(
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_tool_fact!(
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "repaired_args",
      effective_on: Date.new(2026, 3, 8),
    )

    create_tool_fact!(
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_readiness: "invalid_args",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_tool_fact!(
      model_ref: "openai/gpt-5.5",
      provider_key: "openai",
      resolved_name: "write_file",
      execution_readiness: "policy_denied",
      entered_execution: false,
      tool_outcome: "not_executed",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_tool_fact!(
      model_ref: "openai/gpt-5.4",
      provider_key: "openai",
      resolved_name: "shell_exec",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "failed",
      failure_class: "timeout",
      failure_code: "mcp_timeout",
      retryable: true,
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    create_tool_fact!(
      sample_origin: "debug",
      model_ref: "debug/mock-model",
      provider_key: "dev",
      resolved_name: "debug_tool",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 9),
    )

    get statistics_path

    assert_response :success
    assert_includes response.body, "Runtime tool reliability"
    assert_includes response.body, "Executable rate"
    assert_includes response.body, "60%"
    assert_includes response.body, "3 / 5 model attempts"
    assert_includes response.body, "First-pass success"
    assert_includes response.body, "20%"
    assert_includes response.body, "Repair-assisted success"
    assert_includes response.body, "Tool success"
    assert_includes response.body, "66.7%"
    assert_includes response.body, "Policy denied"
    assert_includes response.body, "1"
    assert_includes response.body, "By reliability model"
    assert_includes response.body, "openai/gpt-5.4"
    assert_includes response.body, "By tool"
    assert_includes response.body, "shell_exec"
    assert_includes response.body, "By failure class"
    assert_includes response.body, "timeout"
    assert_includes response.body, "By reliability day"
    assert_includes response.body, "2026-03-08"
    assert_not_includes response.body, "debug/mock-model"
    assert_not_includes response.body, "debug_tool"
  end

  private

    def sign_in!(email:, role: :owner)
      identity =
        Identity.create!(
          email: email,
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      User.create!(identity: identity, role: role)

      post session_path, params: { email: email, password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_tool_fact!(overrides = {})
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

    def uuidv7
      ActiveRecord::Base.with_connection do |connection|
        connection.select_value("select uuidv7()")
      end
    end
end
