require "test_helper"
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"

class Cybros::ProgrammableAgentFixtureTest < ActiveSupport::TestCase
  test "identity is deterministic and exposes turn hooks" do
    identity = Cybros::ProgrammableAgentFixture.identity

    assert_equal "fixture-program", identity.fetch("agent_program_key")
    assert_equal "fixture-deployment", identity.fetch("agent_deployment_key")
    assert_equal "fixture-deployment-v1", identity.fetch("deployment_fingerprint")
    assert_equal "fixture-ruby-sdk/1.0", identity.fetch("agent_sdk_version")
    assert_includes identity.fetch("supported_methods"), "turn.prepare"
    assert_includes identity.fetch("supported_methods"), "turn.compose"
  end

  test "server responds to health prepare and compose over http" do
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
          method: "turn.prepare",
          params: { "conversation_id" => "conv_123" },
        )

      assert_equal "2.0", prepare.fetch("jsonrpc")
      assert_equal 1, prepare.fetch("id")
      assert_equal true, prepare.dig("result", "prepared_plan", "fixture")
      assert_equal "conv_123", prepare.dig("result", "prepared_plan", "conversation_id")

      compose =
        rpc_json(
          "#{server.base_url}/rpc",
          id: 2,
          method: "turn.compose",
          params: { "conversation_run_id" => "run_123" },
        )

      assert_equal "2.0", compose.fetch("jsonrpc")
      assert_equal "fixture compose response", compose.dig("result", "output", "content")
    ensure
      server.shutdown
    end
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
          method: "turn.prepare",
          params: { "conversation_id" => "conv_cli" },
        )

      assert_equal true, prepare.dig("result", "prepared_plan", "fixture")
      assert_equal "conv_cli", prepare.dig("result", "prepared_plan", "conversation_id")
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

  test "turn prepare switch-target proposes the paired alternate target when older visible targets exist" do
    current_target_id = "target-current"
    proposed_target_id = nil

    callback_rpc =
      lambda do |_session, method_name, params|
        case method_name
        when "execution_target.list"
          {
            "targets" => [
              { "id" => "approval-old", "name" => "approval-1773037603066 Primary" },
              { "id" => current_target_id, "name" => "target-switch-123 Primary" },
              { "id" => "target-alternate", "name" => "target-switch-123 Alternate" },
            ],
          }
        when "execution_target.propose"
          proposed_target_id = params.fetch("execution_target_id")
          {
            "switch_decision" => {
              "decision" => "confirm",
            },
          }
        else
          flunk("unexpected callback #{method_name}")
        end
      end

    fixture = Cybros::ProgrammableAgentFixture
    eigenclass = class << fixture; self end
    original_callback_rpc = fixture.method(:callback_rpc)
    eigenclass.send(:define_method, :callback_rpc) do |*args|
      callback_rpc.call(*args)
    end

    begin
      prepare =
        fixture.rpc_result(
          "turn.prepare",
          {
            "conversation_id" => "conv_switch",
            "user_input" => "[fixture:switch-target]",
            "execution_target_id" => current_target_id,
            "callback_session" => { "endpoint" => "http://fixture.test/rpc", "bearer" => "secret" },
          },
        )

      assert_equal "target-alternate", proposed_target_id
      assert_equal "target-alternate", prepare.dig("approval_state", "proposed_execution_target_id")
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
