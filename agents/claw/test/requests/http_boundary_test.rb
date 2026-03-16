require_relative "../test_helper"

class HttpBoundaryTest < ActionDispatch::IntegrationTest
  test "GET /health returns JSON health payload" do
    get "/health"

    assert_response :success
    assert_equal "application/json", response.media_type

    payload = JSON.parse(response.body)
    assert_equal true, payload.fetch("ok")
    assert_equal "healthy", payload.fetch("status")
    assert_kind_of Hash, payload.fetch("identity")
  end

  test "POST /rpc rejects invalid bearer with JSON-RPC error payload" do
    post "/rpc",
         params: JSON.generate(jsonrpc_request(id: 1, method: "agent.health", params: {})),
         headers: json_headers(authorization: "Bearer wrong://agent")

    assert_response :internal_server_error
    assert_equal "application/json", response.media_type

    payload = JSON.parse(response.body)
    assert_equal "2.0", payload.fetch("jsonrpc")
    assert_nil payload.fetch("id")
    assert_equal(-32_000, payload.dig("error", "code"))
    assert_equal "invalid bearer", payload.dig("error", "message")
  end

  test "POST /rpc rejects malformed JSON with parse error payload" do
    post "/rpc",
         params: "{\"jsonrpc\":",
         headers: json_headers

    assert_response :bad_request
    assert_equal "application/json", response.media_type

    payload = JSON.parse(response.body)
    assert_equal "2.0", payload.fetch("jsonrpc")
    assert_nil payload.fetch("id")
    assert_equal(-32_700, payload.dig("error", "code"))
    refute_empty payload.dig("error", "message").to_s
  end

  test "POST /rpc returns JSON-RPC response for agent.health" do
    post "/rpc",
         params: JSON.generate(jsonrpc_request(id: 2, method: "agent.health", params: {})),
         headers: json_headers

    assert_response :success
    assert_equal "application/json", response.media_type

    payload = JSON.parse(response.body)
    assert_equal "2.0", payload.fetch("jsonrpc")
    assert_equal 2, payload.fetch("id")
    assert_equal true, payload.dig("result", "healthy")
    assert_equal "healthy", payload.dig("result", "status")
  end

  private

  def json_headers(authorization: "Bearer secret://agent")
    {
      "CONTENT_TYPE" => "application/json",
      "ACCEPT" => "application/json",
      "Authorization" => authorization
    }
  end

  def jsonrpc_request(id:, method:, params:)
    {
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }
  end
end
