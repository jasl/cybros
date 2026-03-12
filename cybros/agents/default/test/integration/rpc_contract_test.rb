require_relative "../test_helper"

class RPCContractTest < Minitest::Test
  def test_http_json_rpc_serves_initialize_describe_health_schemas_and_capabilities
    host = build_host.start

    initialize_payload = rpc_json(host.rpc_url, id: 1, method: "initialize", params: {})
    describe_payload = rpc_json(host.rpc_url, id: 2, method: "agent.describe", params: {})
    health_payload = rpc_json(host.rpc_url, id: 3, method: "agent.health", params: {})
    schemas_payload = rpc_json(host.rpc_url, id: 4, method: "agent.schemas.get", params: {})
    handshake_payload = rpc_json(host.rpc_url, id: 5, method: "capabilities.handshake", params: {})
    refresh_payload = rpc_json(host.rpc_url, id: 6, method: "capabilities.refresh", params: { "reason" => "manual" })

    assert_equal "default", initialize_payload.dig("result", "identity", "agent_program_key")
    assert_equal "deployment:test-default", initialize_payload.dig("result", "identity", "deployment_fingerprint")
    assert_includes initialize_payload.dig("result", "identity", "supported_methods"), "on_conversation_created"
    assert_includes initialize_payload.dig("result", "identity", "supported_methods"), "on_lane_first_user_message"
    assert_equal "Default", describe_payload.dig("result", "name")
    assert_equal true, health_payload.dig("result", "healthy")
    assert_equal "object", schemas_payload.dig("result", "global_config_schema", "type")
    assert_equal "object", schemas_payload.dig("result", "conversation_config_schema", "type")
    assert_equal "refreshed", handshake_payload.dig("result", "status")
    assert_equal "default-agent-capabilities:v1", handshake_payload.dig("result", "agent_capabilities_version")
    assert_equal "manual", refresh_payload.dig("result", "refresh_reason")
  ensure
    host&.shutdown
  end

  def test_before_agent_step_returns_typed_planning_with_staged_mutations_and_cutover_fields
    callback = TestSupport::CallbackHarness.new.start
    host = build_host.start
    capability_snapshot = {
      "capability_registry_snapshot_id" => "csnap_fixture",
      "effective_tools" => [
        {
          "logical_tool_name" => "compact_context",
          "effective_tool_id" => "etool_compact",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://compact_context",
        },
        {
          "logical_tool_name" => "subagent_spawn",
          "effective_tool_id" => "etool_subagent_spawn",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://subagent_spawn",
        },
      ],
    }

    payload =
      rpc_json(
        host.rpc_url,
        id: 5,
        method: "before_agent_step",
        params: {
          "conversation_id" => "conversation:test-default",
          "execution_target_id" => "target-primary",
          "capability_snapshot" => capability_snapshot,
          "user_input" => "[fixture:stage-state] [fixture:replay-kv] [fixture:switch-target] Verify the workspace status",
          "callback_session" => {
            "endpoint" => callback.rpc_url,
            "bearer" => callback.required_bearer,
          },
        }
      )

    result = payload.fetch("result")

    assert_equal(
      %w[stage-state replay-kv switch-target],
      result.dig("planning", "step_plan", "fixture_scenarios")
    )
    assert_match("Verify the workspace status", result.dig("planning", "step_plan", "summary"))
    assert_equal "clear", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "op")
    assert_equal "system", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "buffer_name")
    assert_equal "put", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "op")
    assert_equal "system", result.dig("planning", "staged_mutations", "prompt_buffer_ops", 1, "entry", "buffer_name")
    assert_equal({ "tone" => "concise" }, result.dig("planning", "staged_mutations", "public_settings_patch"))
    assert_equal({ "mode" => "review" }, result.dig("planning", "staged_mutations", "agent_config_patch"))
    assert_equal 2, result.dig("planning", "staged_mutations", "kv_ops").size
    assert_equal "csnap_fixture", result.dig("planning", "tool_surface", "capability_registry_snapshot_id")
    assert_equal %w[etool_compact etool_subagent_spawn], result.dig("planning", "tool_surface", "selected_tool_ids")
    assert_equal "surface_callback_harness", result.dig("planning", "tool_surface", "tool_surface_id")
    assert_equal "target-alternate", result.dig("planning", "execution_target_proposal", "execution_target_id")

    assert_equal(
      [
        "tool_surface.manifest",
        "execution_target.list",
      ],
      callback.calls.map { |call| call.fetch("method") }
    )
  ensure
    host&.shutdown
    callback&.shutdown
  end

  def test_bootstrap_hooks_return_append_only_authority_tasks
    host = build_host.start

    conversation_payload =
      rpc_json(
        host.rpc_url,
        id: 11,
        method: "on_conversation_created",
        params: {
          "conversation_id" => "conversation:test-default",
          "conversation_kind" => "root",
          "agent_key" => "main",
          "lane_id" => "lane-main",
        },
      )
    main_lane_first_user_payload =
      rpc_json(
        host.rpc_url,
        id: 12,
        method: "on_lane_first_user_message",
        params: {
          "conversation_id" => "conversation:test-default",
          "lane_id" => "lane-main",
          "lane_role" => "main",
          "agent_key" => "main",
          "user_node_id" => "message-1",
        },
      )
    branch_lane_first_user_payload =
      rpc_json(
        host.rpc_url,
        id: 13,
        method: "on_lane_first_user_message",
        params: {
          "conversation_id" => "conversation:branch",
          "conversation_kind" => "branch",
          "lane_id" => "lane-branch",
          "lane_role" => "branch",
          "agent_key" => "main",
          "user_node_id" => "message-branch-1",
        },
      )

    assert_equal "create_task", conversation_payload.dig("result", "actions", 0, "type")
    assert_equal "append", conversation_payload.dig("result", "actions", 0, "placement")
    assert_match(/\Acybros_/i, conversation_payload.dig("result", "actions", 0, "logical_tool_name"))
    assert_equal ["cybros_generate_title"], main_lane_first_user_payload.fetch("result").fetch("actions").map { |action| action["logical_tool_name"] }
    assert_equal ["cybros_generate_title", "cybros_enqueue_lane_summary"],
                 branch_lane_first_user_payload.fetch("result").fetch("actions").map { |action| action["logical_tool_name"] }
    assert branch_lane_first_user_payload.fetch("result").fetch("actions").all? { |action| action["placement"] == "append" }
  ensure
    host&.shutdown
  end

  def test_before_agent_step_replaces_the_system_prompt_buffer_without_extra_callback_state
    callback = TestSupport::CallbackHarness.new.start
    host = build_host.start

    payload =
      rpc_json(
        host.rpc_url,
        id: 7,
        method: "before_agent_step",
        params: {
          "conversation_id" => "conversation:test-default",
          "execution_target_id" => "target-primary",
          "user_input" => "Allocate the next seq",
          "callback_session" => {
            "endpoint" => callback.rpc_url,
            "bearer" => callback.required_bearer,
          },
        }
      )

    ops = payload.dig("result", "planning", "staged_mutations", "prompt_buffer_ops")
    entry = ops.fetch(1).fetch("entry")

    assert_equal "clear", ops.fetch(0).fetch("op")
    assert_equal "system", ops.fetch(0).fetch("buffer_name")
    assert_equal "system", entry.fetch("buffer_name")
    assert_equal 10, entry.fetch("seq")
    refute_includes callback.calls.map { |call| call.fetch("method") }, "lane.prompt_buffer.list"
  ensure
    host&.shutdown
    callback&.shutdown
  end

  def test_on_context_pressure_before_subagent_spawn_before_finalize_output_after_task_notice_and_after_subagent_result_return_typed_action_envelopes
    host = build_host.start

    context_pressure_payload =
      rpc_json(
        host.rpc_url,
        id: 5,
        method: "on_context_pressure",
        params: {
          "context_pressure" => {
            "budget_state" => "soft_limit_reached",
            "budget_action" => "advise_compact",
          },
          "provider_input" => {
            "tools" => [
              {
                "name" => "compact_context",
                "logical_tool_name" => "compact_context",
              },
            ],
          },
        },
      )
    before_subagent_payload =
      rpc_json(
        host.rpc_url,
        id: 6,
        method: "before_subagent_spawn",
        params: {
          "subagent_request" => {
            "tool_name" => "subagent_run",
            "tool_call_id" => "tc_subagent",
            "arguments" => {
              "name" => "researcher",
              "prompt" => "Investigate the repo",
            },
          },
        },
      )
    finalize_payload =
      rpc_json(
        host.rpc_url,
        id: 7,
        method: "before_finalize_output",
        params: {
          "execution_target_id" => "target-primary",
          "capability_registry_snapshot_id" => "csnap_fixture",
          "execution_context" => {
            "conversation_id" => "conversation:test-default",
          },
          "planning" => {
            "step_plan" => {
              "summary" => "inspect the current repository status",
            },
          },
          "provider_input" => {
            "messages" => [
              { "role" => "user", "content" => "Can you summarize what you are about to do?" },
            ],
            "tools" => [
              {
                "name" => "compact_context",
                "description" => "compact",
                "parameters" => {},
                "logical_tool_name" => "compact_context",
                "effective_tool_id" => "etool_compact",
                "implementation_source" => "agent_program",
                "implementation_ref" => "agent://compact_context",
              },
            ],
          },
          "draft_output" => {
            "content" => "Draft output from the model",
          },
        }
      )
    task_notice_payload =
      rpc_json(
        host.rpc_url,
        id: 8,
        method: "after_task_notice",
        params: {
          "planning" => {
            "step_plan" => {
              "summary" => "inspect the current repository status",
            },
          },
          "provider_input" => {
            "messages" => [
              { "role" => "user", "content" => "Please run the checks." },
            ],
          },
          "task_notice" => {
            "task_id" => "task-123",
            "subject_kind" => "agent_step",
            "status" => "failed",
            "notice" => {
              "kind" => "provider_error",
            },
            "error" => {
              "class" => "RuntimeError",
              "message" => "tool execution crashed",
            },
          },
        }
      )
    task_notice_task_payload =
      rpc_json(
        host.rpc_url,
        id: 10,
        method: "after_task_notice",
        params: {
          "task_notice" => {
            "task_id" => "task-456",
            "subject_kind" => "task",
            "status" => "failed",
            "notice" => {
              "kind" => "remote_tool_failed",
            },
            "logical_tool_name" => "shell_exec",
            "error" => {
              "class" => "RuntimeError",
              "message" => "shell_exec crashed",
            },
          },
        },
      )
    subagent_payload =
      rpc_json(
        host.rpc_url,
        id: 9,
        method: "after_subagent_result",
        params: {
          "subagent_result" => {
            "subagent_id" => "subagent-123",
            "status" => "succeeded",
            "assistant_output_candidate" => {
              "format" => "text",
              "content" => "Candidate answer from the worker",
              "scope" => "partial",
            },
          },
        },
      )

    context_pressure_actions = context_pressure_payload.dig("result", "actions")
    before_subagent_status = before_subagent_payload.dig("result", "actions", 0, "text").to_s
    finalize_content = finalize_payload.dig("result", "actions", 0, "message", "content").to_s
    error_content = task_notice_payload.dig("result", "actions", 0, "message", "content").to_s
    task_notice_status = task_notice_task_payload.dig("result", "actions", 0, "text").to_s
    subagent_status = subagent_payload.dig("result", "actions", 0, "text").to_s

    assert_equal "set_step_status", context_pressure_actions.dig(0, "type")
    assert_includes context_pressure_actions.dig(0, "text").to_s.downcase, "context"
    assert_equal "create_task", context_pressure_actions.dig(1, "type")
    assert_equal "prepend", context_pressure_actions.dig(1, "placement")
    assert_equal "compact_context", context_pressure_actions.dig(1, "logical_tool_name")
    assert_equal "set_step_status", before_subagent_payload.dig("result", "actions", 0, "type")
    assert_includes before_subagent_status.downcase, "subagent"
    assert_includes before_subagent_status, "subagent_run"
    assert_equal "emit_message", finalize_payload.dig("result", "actions", 0, "type")
    assert_equal "Draft output from the model", finalize_content
    assert_nil finalize_payload.dig("result", "tool_surface")
    assert_equal "emit_message", task_notice_payload.dig("result", "actions", 0, "type")
    assert_includes error_content, "tool execution crashed"
    assert_includes error_content, "Please run the checks."
    assert_includes error_content, "provider_error"
    assert_equal "set_step_status", task_notice_task_payload.dig("result", "actions", 0, "type")
    assert_includes task_notice_status, "remote_tool_failed"
    assert_includes task_notice_status, "shell_exec"
    assert_includes task_notice_status, "shell_exec crashed"
    assert_equal "set_step_status", subagent_payload.dig("result", "actions", 0, "type")
    assert_includes subagent_status.downcase, "summarizing"
    assert_includes subagent_status, "subagent-123"
  ensure
    host&.shutdown
  end

  private

  def build_host
    Cybros::Agents::Default::Application.new(
      source_root: TestPaths.source_root,
      host: "127.0.0.1",
      port: 0,
      deployment_fingerprint: "deployment:test-default",
      required_bearer: "secret://agent"
    )
  end

  def rpc_json(url, id:, method:, params:)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer secret://agent"
    request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })

    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    assert_equal "200", response.code
    JSON.parse(response.body)
  end
end
