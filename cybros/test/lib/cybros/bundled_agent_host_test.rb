require "test_helper"
require "json"
require "net/http"
require "uri"

class Cybros::BundledAgentHostTest < ActiveSupport::TestCase
  test "default bundled agent host responds to required methods" do
    host = Cybros::BundledAgentHost::Application.new(source_root: Rails.root.join("agents/default"))

    assert_equal Agents::Protocol::DEFAULT_SUPPORTED_METHODS, host.supported_methods
  end

  test "bundled host serves initialize and health over http json-rpc" do
    host =
      Cybros::BundledAgentHost::Application.new(
        source_root: Rails.root.join("agents/default"),
        deployment_fingerprint: "bundled-host-http-test",
        required_bearer: "secret://bundled",
      ).start

    initialize_result =
      rpc_json(
        host.rpc_url,
        id: 1,
        method: "initialize",
        params: {},
        bearer: "secret://bundled",
      )

    health_result =
      rpc_json(
        host.rpc_url,
        id: 2,
        method: "agent.health",
        params: {},
        bearer: "secret://bundled",
      )

    assert_equal "default", initialize_result.dig("result", "identity", "agent_program_key")
    assert_equal "bundled-host-http-test", initialize_result.dig("result", "identity", "deployment_fingerprint")
    assert_equal true, health_result.dig("result", "healthy")
  ensure
    host&.shutdown
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
