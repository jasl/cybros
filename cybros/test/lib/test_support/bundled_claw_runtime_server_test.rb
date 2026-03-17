require "test_helper"
require "json"
require "net/http"
require "uri"

class TestSupport::BundledClawRuntimeServerTest < ActiveSupport::TestCase
  test "server serves health and initialize for the bundled claw runtime" do
    server =
      TestSupport::BundledClawRuntimeServer.new(
        source_root: Agents::BundledSources.path_for("claw"),
        deployment_fingerprint: "deployment:test-claw",
        required_bearer: "secret://bundled",
      ).start

    health_payload = JSON.parse(Net::HTTP.get(URI(server.health_url)))
    initialize_payload =
      rpc_json(
        server.rpc_url,
        id: 1,
        method: "initialize",
        params: {},
        bearer: "secret://bundled",
      )

    assert_equal true, health_payload.fetch("ok")
    assert_equal "claw", health_payload.dig("identity", "agent_key")
    assert_equal "claw", initialize_payload.dig("result", "identity", "agent_key")
    assert_equal "deployment:test-claw", initialize_payload.dig("result", "identity", "deployment_fingerprint")
  ensure
    server&.shutdown
  end

  test "server reconfigure swaps the live deployment identity without restarting" do
    server =
      TestSupport::BundledClawRuntimeServer.new(
        source_root: Agents::BundledSources.path_for("claw"),
        deployment_fingerprint: "deployment:test-claw:v1",
        required_bearer: "secret://bundled:v1",
      ).start

    server.reconfigure!(
      workspace_root: nil,
      deployment_fingerprint: "deployment:test-claw:v2",
      required_bearer: "secret://bundled:v2",
    )

    initialize_payload =
      rpc_json(
        server.rpc_url,
        id: 2,
        method: "initialize",
        params: {},
        bearer: "secret://bundled:v2",
      )

    assert_equal "deployment:test-claw:v2", initialize_payload.dig("result", "identity", "deployment_fingerprint")
  ensure
    server&.shutdown
  end

  private

    def rpc_json(url, id:, method:, params:, bearer:)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{bearer}"
      request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })

      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      assert_equal "200", response.code
      JSON.parse(response.body)
    end
end
