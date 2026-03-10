require "test_helper"

class RPCContractTest < Minitest::Test
  def test_http_json_rpc_serves_initialize_describe_health_and_schemas
    host = build_host.start

    initialize_payload = rpc_json(host.rpc_url, id: 1, method: "initialize", params: {})
    describe_payload = rpc_json(host.rpc_url, id: 2, method: "agent.describe", params: {})
    health_payload = rpc_json(host.rpc_url, id: 3, method: "agent.health", params: {})
    schemas_payload = rpc_json(host.rpc_url, id: 4, method: "agent.schemas.get", params: {})

    assert_equal "default", initialize_payload.dig("result", "identity", "agent_program_key")
    assert_equal "deployment:test-default", initialize_payload.dig("result", "identity", "deployment_fingerprint")
    assert_equal "Default", describe_payload.dig("result", "name")
    assert_equal true, health_payload.dig("result", "healthy")
    assert_equal "object", schemas_payload.dig("result", "global_config_schema", "type")
    assert_equal "object", schemas_payload.dig("result", "conversation_config_schema", "type")
  ensure
    host&.shutdown
  end

  def test_turn_prepare_preserves_fixture_style_callbacks_and_approval_flow
    callback = TestSupport::CallbackHarness.new.start
    host = build_host.start

    payload =
      rpc_json(
        host.rpc_url,
        id: 5,
        method: "turn.prepare",
        params: {
          "conversation_id" => "conversation:test-default",
          "execution_target_id" => "target-primary",
          "user_input" => "[fixture:stage-state] [fixture:replay-kv] [fixture:switch-target] [fixture:approval] Verify the workspace status",
          "callback_session" => {
            "endpoint" => callback.rpc_url,
            "bearer" => callback.required_bearer,
          },
        }
      )

    result = payload.fetch("result")

    assert_equal(
      %w[stage-state replay-kv switch-target approval],
      result.dig("prepared_plan", "fixture_scenarios")
    )
    assert_equal "pending_confirmation", result.dig("approval_state", "status")
    assert_equal "target_switch", result.dig("approval_state", "reason")
    assert_equal "target-alternate", result.dig("approval_state", "proposed_execution_target_id")
    assert_match("Verify the workspace status", result.dig("prepared_plan", "summary"))
    assert_equal "system", result.dig("prompt_fragments", 0, "role")

    assert_equal(
      [
        "conversation.settings.update",
        "conversation.config.update",
        "lane.kv.set",
        "lane.kv.set",
        "lane.kv.set",
        "execution_target.list",
        "execution_target.propose",
      ],
      callback.calls.map { |call| call.fetch("method") }
    )
    assert_equal(
      %w[fixture-kv fixture-kv-replay fixture-kv-replay],
      callback.received("lane.kv.set").map { |call| call.dig("params", "operation_id") }
    )
  ensure
    host&.shutdown
    callback&.shutdown
  end

  def test_turn_compose_and_handle_error_return_context_aware_messages
    host = build_host.start

    compose_payload =
      rpc_json(
        host.rpc_url,
        id: 6,
        method: "turn.compose",
        params: {
          "execution_target_id" => "target-primary",
          "prepared_plan" => {
            "summary" => "inspect the current repository status",
          },
          "provider_input" => {
            "messages" => [
              { "role" => "user", "content" => "Can you summarize what you are about to do?" },
            ],
          },
        }
      )
    handle_error_payload =
      rpc_json(
        host.rpc_url,
        id: 7,
        method: "turn.handle_error",
        params: {
          "prepared_plan" => {
            "summary" => "inspect the current repository status",
          },
          "provider_input" => {
            "messages" => [
              { "role" => "user", "content" => "Please run the checks." },
            ],
          },
          "error" => {
            "class" => "RuntimeError",
            "message" => "tool execution crashed",
          },
        }
      )

    compose_content = compose_payload.dig("result", "output", "content").to_s
    error_content = handle_error_payload.dig("result", "output", "content").to_s

    assert_includes compose_content, "inspect the current repository status"
    assert_includes compose_content, "Can you summarize what you are about to do?"
    assert_includes error_content, "tool execution crashed"
    assert_includes error_content, "Please run the checks."
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
