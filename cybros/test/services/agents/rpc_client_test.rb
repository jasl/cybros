require "test_helper"

class Agents::RPCClientTest < ActiveSupport::TestCase
  test "call self-heals a stale bundled claw endpoint and retries once" do
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    stale_endpoint = "http://127.0.0.1:1/rpc"
    agent.update!(endpoint_url: stale_endpoint)

    result = Agents::RPCClient.new(agent: agent).call("initialize")

    assert result.fetch("identity").is_a?(Hash)
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+/rpc\z}, agent.reload.endpoint_url)
    refute_equal stale_endpoint, agent.endpoint_url
  end

  test "call does not self-heal non-bundled runtimes on connection failure" do
    agent =
      create_agent!(
        name: "External Agent",
        source_kind: "custom",
        endpoint_url: "http://127.0.0.1:1/rpc",
        deployment_bearer_secret_ref: "secret://external",
        deployment_fingerprint: "deployment:external:v1",
        transport_kind: "http_jsonrpc",
        protocol_version: "agent_rpc.v1",
        published_contract_fingerprint: "contract:external:v1",
        config_schema_fingerprint: "config:external:v1",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        status: "active",
        health_status: "healthy",
        activated_at: Time.current.change(usec: 0),
      )

    error =
      assert_raises(Agents::RPCClient::TransportError) do
        Agents::RPCClient.new(agent: agent).call("initialize")
      end

    assert_match(/Connection refused|Failed to open TCP connection/, error.message)
    assert_equal "http://127.0.0.1:1/rpc", agent.reload.endpoint_url
  end
end
