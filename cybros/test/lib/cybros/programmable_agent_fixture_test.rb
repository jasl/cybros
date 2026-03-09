require "test_helper"
require "json"
require "net/http"
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
