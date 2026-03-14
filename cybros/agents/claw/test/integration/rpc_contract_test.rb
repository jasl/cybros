require "test_helper"

class RPCContractTest < ActiveSupport::TestCase
  test "application serves initialize describe health schemas and capabilities" do
    initialize_payload = application.call(method_name: "initialize", params: {})
    describe_payload = application.call(method_name: "agent.describe", params: {})
    health_payload = application.call(method_name: "agent.health", params: {})
    schemas_payload = application.call(method_name: "agent.schemas.get", params: {})
    handshake_payload = application.call(method_name: "capabilities.handshake", params: {})
    refresh_payload = application.call(method_name: "capabilities.refresh", params: { "reason" => "manual" })

    assert_equal "claw", initialize_payload.dig("identity", "agent_program_key")
    assert_equal "deployment:test-claw", initialize_payload.dig("identity", "deployment_fingerprint")
    assert_includes initialize_payload.dig("identity", "supported_methods"), "on_conversation_created"
    assert_includes initialize_payload.dig("identity", "supported_methods"), "on_lane_first_user_message"
    assert_equal "Claw", describe_payload.dig("name")
    assert_equal true, health_payload.dig("healthy")
    assert_equal "object", schemas_payload.dig("global_config_schema", "type")
    assert_equal "object", schemas_payload.dig("conversation_config_schema", "type")
    assert_equal "refreshed", handshake_payload.dig("status")
    assert_equal "claw-agent-capabilities:v1", handshake_payload.dig("agent_capabilities_version")
    assert_equal "manual", refresh_payload.dig("refresh_reason")
  end

  test "application imports descriptor based attachments" do
    payload =
      application.call(
        method_name: "attachments.import",
        params: {
          "attachments" => [
            {
              "id" => "attachment-1",
              "filename" => "error.png",
              "content_type" => "image/png",
              "byte_size" => 128,
              "digest" => "sha256:abc123",
              "signed_download_url" => "https://example.test/rails/active_storage/blobs/redirect/signed/error.png",
              "workspace" => {
                "conversation_id" => "conversation:test-default",
                "logical_workspace_id" => "workspace:test-default"
              }
            }
          ]
        }
      )

    import = payload.fetch("imports").first

    assert_equal "attachment-1", import.fetch("id")
    assert_equal "attachment_import", import.dig("remote_ref", "kind")
    assert_match %r{\Aattachment-import://attachment-1/}, import.dig("remote_ref", "locator")
    assert_equal "error.png", import.dig("remote_ref", "filename")
  end

  test "before_agent_step returns typed planning with staged mutations and cutover fields" do
    callback = TestSupport::CallbackHarness.new.start
    capability_snapshot = {
      "capability_registry_snapshot_id" => "csnap_fixture",
      "effective_tools" => [
        {
          "logical_tool_name" => "compact_context",
          "effective_tool_id" => "etool_compact",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://compact_context"
        },
        {
          "logical_tool_name" => "subagent_spawn",
          "effective_tool_id" => "etool_subagent_spawn",
          "implementation_source" => "kernel",
          "implementation_ref" => "kernel://subagent_spawn"
        }
      ]
    }

    payload =
      application.call(
        method_name: "before_agent_step",
        params: {
          "conversation_id" => "conversation:test-default",
          "execution_target_id" => "target-primary",
          "capability_snapshot" => capability_snapshot,
          "user_input" => "[fixture:stage-state] [fixture:replay-kv] [fixture:switch-target] Verify the workspace status",
          "callback_session" => {
            "endpoint" => callback.rpc_url,
            "bearer" => callback.required_bearer
          }
        }
      )

    assert_equal(
      %w[stage-state replay-kv switch-target],
      payload.dig("planning", "step_plan", "fixture_scenarios")
    )
    assert_match("Verify the workspace status", payload.dig("planning", "step_plan", "summary"))
    assert_equal "clear", payload.dig("planning", "staged_mutations", "prompt_buffer_ops", 0, "op")
    assert_equal({ "tone" => "concise" }, payload.dig("planning", "staged_mutations", "public_settings_patch"))
    assert_equal({ "mode" => "review" }, payload.dig("planning", "staged_mutations", "agent_config_patch"))
    assert_equal 2, payload.dig("planning", "staged_mutations", "kv_ops").size
    assert_equal "surface_callback_harness", payload.dig("planning", "tool_surface", "tool_surface_id")
    assert_equal "target-alternate", payload.dig("planning", "execution_target_proposal", "execution_target_id")
    assert_equal [ "tool_surface.manifest", "execution_target.list" ], callback.calls.map { |call| call.fetch("method") }
  ensure
    callback&.shutdown
  end

  test "bootstrap and lifecycle hooks return claw-compatible action envelopes" do
    conversation_payload =
      application.call(
        method_name: "on_conversation_created",
        params: {
          "conversation_id" => "conversation:test-default",
          "conversation_kind" => "root",
          "agent_key" => "main",
          "lane_id" => "lane-main"
        }
      )
    lane_payload =
      application.call(
        method_name: "on_lane_first_user_message",
        params: {
          "conversation_id" => "conversation:branch",
          "conversation_kind" => "branch",
          "lane_id" => "lane-branch",
          "lane_role" => "branch",
          "agent_key" => "main",
          "user_node_id" => "message-branch-1"
        }
      )
    context_pressure_payload =
      application.call(
        method_name: "on_context_pressure",
        params: {
          "context_pressure" => {
            "budget_state" => "soft_limit_reached",
            "budget_action" => "advise_compact"
          },
          "provider_input" => {
            "tools" => [
              {
                "name" => "compact_context",
                "logical_tool_name" => "compact_context"
              }
            ]
          }
        }
      )
    before_subagent_payload =
      application.call(
        method_name: "before_subagent_spawn",
        params: {
          "subagent_request" => {
            "tool_name" => "subagent_run"
          }
        }
      )
    finalize_payload =
      application.call(
        method_name: "before_finalize_output",
        params: {
          "draft_output" => {
            "content" => "Draft output from the model"
          }
        }
      )
    task_notice_payload =
      application.call(
        method_name: "after_task_notice",
        params: {
          "task_notice" => {
            "task_id" => "task-456",
            "subject_kind" => "task",
            "status" => "failed",
            "notice" => {
              "kind" => "remote_tool_failed"
            },
            "logical_tool_name" => "shell_exec",
            "error" => {
              "class" => "RuntimeError",
              "message" => "shell_exec crashed"
            }
          }
        }
      )
    subagent_payload =
      application.call(
        method_name: "after_subagent_result",
        params: {
          "subagent_result" => {
            "subagent_id" => "subagent-123",
            "status" => "succeeded",
            "assistant_output_candidate" => {
              "scope" => "partial"
            }
          }
        }
      )

    assert_equal "create_task", conversation_payload.dig("actions", 0, "type")
    assert_equal [ "cybros_generate_title", "cybros_enqueue_lane_summary" ], lane_payload.fetch("actions").map { |action| action["logical_tool_name"] }
    assert_equal "create_task", context_pressure_payload.dig("actions", 1, "type")
    assert_equal "set_step_status", before_subagent_payload.dig("actions", 0, "type")
    assert_equal "emit_message", finalize_payload.dig("actions", 0, "type")
    assert_equal "Draft output from the model", finalize_payload.dig("actions", 0, "message", "content")
    assert_equal "set_step_status", task_notice_payload.dig("actions", 0, "type")
    assert_includes task_notice_payload.dig("actions", 0, "text"), "shell_exec crashed"
    assert_equal "set_step_status", subagent_payload.dig("actions", 0, "type")
    assert_includes subagent_payload.dig("actions", 0, "text"), "subagent-123"
  end

  test "unsupported methods raise the claw-compatible key error" do
    error = assert_raises(KeyError) do
      application.call(method_name: "agent.unsupported", params: {})
    end

    assert_includes error.message, "unsupported bundled claw RPC method"
  end

  private

  def application
    @application ||=
      Cybros::Agents::Claw::Application.new(
        source_root: TestPaths.source_root,
        deployment_fingerprint: "deployment:test-claw",
        required_bearer: "secret://agent"
      )
  end
end
