require "test_helper"

class StatisticsPageSubagentScopeTest < ActionDispatch::IntegrationTest
  setup do
    Statistics::ToolCallFact.delete_all
  end

  test "statistics page groups runtime facts by execution scope" do
    sign_in!(email: "owner@example.com")

    create_tool_fact!(
      execution_scope: "parent",
      model_ref: "openai/gpt-5.4",
      resolved_name: "subagent_run",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "first_pass",
      effective_on: Date.new(2026, 3, 8),
    )

    create_tool_fact!(
      execution_scope: "subagent",
      model_ref: "openai/gpt-5.4",
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
      execution_scope: "subagent",
      model_ref: "openai/gpt-5.4",
      resolved_name: "read_file",
      execution_readiness: "executable",
      entered_execution: true,
      tool_outcome: "success",
      model_attempt_class: "repaired_args",
      effective_on: Date.new(2026, 3, 9),
    )

    get statistics_path

    assert_response :success
    assert_includes response.body, "By execution scope"
    assert_includes response.body, "parent"
    assert_includes response.body, "subagent"
    assert_includes response.body, "subagent_run"
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
