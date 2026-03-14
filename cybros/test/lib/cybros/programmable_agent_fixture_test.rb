require "test_helper"
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"

class Cybros::ProgrammableAgentFixtureTest < ActiveSupport::TestCase
  test "identity is deterministic and exposes planning and execution methods" do
    identity = Cybros::ProgrammableAgentFixture.identity

    assert_equal "fixture-program", identity.fetch("agent_program_key")
    assert_equal "fixture-deployment", identity.fetch("agent_deployment_key")
    assert_equal "fixture-deployment-v1", identity.fetch("deployment_fingerprint")
    assert_equal "fixture-ruby-sdk/1.0", identity.fetch("agent_sdk_version")
    assert_equal Agents::Protocol::DEFAULT_SUPPORTED_METHODS, identity.fetch("supported_methods")
  end

  test "server responds to health before_agent_step on_context_pressure before_subagent_spawn and before_finalize_output over http" do
    server = Cybros::ProgrammableAgentFixture::Server.new
    server.start

    begin
      health = get_json("#{server.base_url}/health")
      assert_equal "healthy", health.fetch("status")
      assert_equal "fixture-deployment", health.dig("identity", "agent_deployment_key")

      prepare =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 1,
          method: "before_agent_step",
          params: { "conversation_id" => "conv_123" },
        )

      assert_equal "2.0", prepare.fetch("jsonrpc")
      assert_equal 1, prepare.fetch("id")
      assert_equal true, prepare.dig("result", "planning", "step_plan", "fixture")
      assert_equal "conv_123", prepare.dig("result", "planning", "step_plan", "conversation_id")

      finalize =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 2,
          method: "before_finalize_output",
          params: {
            "conversation_run_id" => "run_123",
            "draft_output" => {
              "content" => "fixture finalized response",
            },
          },
        )
      on_context_pressure =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 5,
          method: "on_context_pressure",
          params: {
            "context_pressure" => {
              "budget_action" => "advise_compact",
            },
          },
        )
      before_subagent_spawn =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 4,
          method: "before_subagent_spawn",
          params: {
            "subagent_request" => {
              "tool_name" => "subagent_run",
            },
          },
        )

      after_subagent_result =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 3,
          method: "after_subagent_result",
          params: {
            "subagent_result" => {
              "subagent_id" => "subagent-fixture",
              "status" => "succeeded",
            },
          },
        )

      assert_equal "2.0", finalize.fetch("jsonrpc")
      assert_equal "emit_message", finalize.dig("result", "actions", 0, "type")
      assert_equal "fixture finalized response", finalize.dig("result", "actions", 0, "message", "content")
      assert_equal "set_step_status", on_context_pressure.dig("result", "actions", 0, "type")
      assert_includes on_context_pressure.dig("result", "actions", 0, "text").to_s, "advise_compact"
      assert_equal "set_step_status", before_subagent_spawn.dig("result", "actions", 0, "type")
      assert_includes before_subagent_spawn.dig("result", "actions", 0, "text").to_s, "subagent_run"
      assert_equal "set_step_status", after_subagent_result.dig("result", "actions", 0, "type")
      assert_includes after_subagent_result.dig("result", "actions", 0, "text").to_s, "subagent-fixture"
    ensure
      server.shutdown
    end
  end

  test "before_agent_step exposes planning-owned tool_surface when capability snapshot is supplied" do
    prepare =
      Cybros::ProgrammableAgentFixture.rpc_result(
        "before_agent_step",
        {
          "conversation_id" => "conv_surface",
          "capability_snapshot" => {
            "capability_registry_snapshot_id" => "csnap_fixture",
            "effective_tools" => [
              {
                "logical_tool_name" => "compact_context",
                "effective_tool_id" => "etool_compact",
                "implementation_source" => "kernel",
                "implementation_ref" => "kernel://compact_context",
              },
            ],
          },
        },
      )

    assert_equal "csnap_fixture", prepare.dig("planning", "tool_surface", "capability_registry_snapshot_id")
    assert_equal ["etool_compact"], prepare.dig("planning", "tool_surface", "selected_tool_ids")
    assert_equal "fixture.before_agent_step", prepare.dig("planning", "tool_surface", "tool_surface_label")
  end

  test "before_agent_step fixture scenarios merge staged kv ops instead of overwriting them" do
    prepare =
      Cybros::ProgrammableAgentFixture.rpc_result(
        "before_agent_step",
        {
          "conversation_id" => "conv_fixture",
          "user_input" => "[fixture:stage-state] [fixture:replay-kv]",
        },
      )

    kv_ops = prepare.dig("planning", "staged_mutations", "kv_ops")

    assert_equal "shared.fixture.plan", kv_ops.dig(0, "key")
    assert_equal({ "status" => "planned" }, kv_ops.dig(0, "value"))
    assert_equal "shared.fixture.replay", kv_ops.dig(1, "key")
    assert_equal "shared.fixture.replay", kv_ops.dig(2, "key")
  end

  test "server supports identity and rpc overrides for failure-path coverage" do
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        identity_overrides: {
          "protocol_version" => "agent_rpc.v2",
          "supported_methods" => %w[initialize agent.describe],
        },
        rpc_overrides: {
          "agent.health" => { "healthy" => false, "status" => "unhealthy" },
        },
      )
    server.start

    begin
      initialize_result = server.rpc_call("initialize")
      health_result = server.rpc_call("agent.health")

      assert_equal "agent_rpc.v2", initialize_result.dig("identity", "protocol_version")
      assert_equal %w[initialize agent.describe], initialize_result.dig("identity", "supported_methods")
      assert_equal false, health_result.fetch("healthy")
      assert_equal "unhealthy", health_result.fetch("status")
    ensure
      server.shutdown
    end
  end

  test "standalone fixture cli serves rpc without requiring ActiveSupport core extensions" do
    script = Rails.root.join("bin/programmable_agent_fixture")
    port = 3919
    pid = nil

    Timeout.timeout(20) do
      _stdin, _stdout, _stderr, wait_thread =
        Open3.popen3(
          script.to_s,
          "--host",
          "127.0.0.1",
          "--port",
          port.to_s,
          chdir: Rails.root.to_s,
        )
      pid = wait_thread.pid

      40.times do
        break if Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/health")).is_a?(Net::HTTPSuccess)

        sleep 0.25
      rescue StandardError
        sleep 0.25
      end

      prepare =
        rpc_json(
          "http://127.0.0.1:#{port}/rpc",
          id: 1,
          method: "before_agent_step",
          params: { "conversation_id" => "conv_cli" },
        )
      finalize =
        rpc_json(
          "http://127.0.0.1:#{port}/rpc",
          id: 2,
          method: "before_finalize_output",
          params: {
            "conversation_run_id" => "run_cli",
            "draft_output" => {
              "content" => "",
            },
          },
        )

      assert_equal true, prepare.dig("result", "planning", "step_plan", "fixture")
      assert_equal "conv_cli", prepare.dig("result", "planning", "step_plan", "conversation_id")
      assert_equal "emit_message", finalize.dig("result", "actions", 0, "type")
      assert_equal "fixture finalized response", finalize.dig("result", "actions", 0, "message", "content")
    end
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  test "before_agent_step switch-target token no longer authors legacy target proposals" do
    fixture = Cybros::ProgrammableAgentFixture
    eigenclass = class << fixture; self end
    original_callback_rpc = fixture.method(:callback_rpc)
    eigenclass.send(:define_method, :callback_rpc) do |*args|
      raise "unexpected callback #{args[1]}"
    end

    begin
      prepare =
        fixture.rpc_result(
          "before_agent_step",
          {
            "conversation_id" => "conv_switch",
            "user_input" => "[fixture:switch-target]",
            "callback_session" => { "endpoint" => "http://fixture.test/rpc", "bearer" => "secret" },
          },
        )

      assert_nil prepare.dig("planning", "execution_target_proposal")
    ensure
      eigenclass.send(:define_method, :callback_rpc, original_callback_rpc)
    end
  end

  private

    def get_json(url)
      response = Net::HTTP.get_response(URI(url))
      assert_equal "200", response.code
      JSON.parse(response.body)
    end

    def rpc_json(url, id:, method:, params:)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })

      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      assert_equal "200", response.code
      JSON.parse(response.body)
    end
end
