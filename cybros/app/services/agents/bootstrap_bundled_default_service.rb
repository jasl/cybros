module Agents
  class BootstrapBundledDefaultService
    DEFAULT_BUNDLED_AGENT_KEY = "claw".freeze
    DEFAULT_AGENT_NAME = "Claw".freeze
    PROTOCOL_VERSION = "agent_rpc.v1".freeze

    class << self
      def ensure_agent!
        new.ensure_agent!
      end

      def bootstrap!
        new.bootstrap!
      end
    end

    def ensure_agent!
      runtime_config = Agents::BundledDefaultRuntimeConfig.resolve
      agent = Agents::Creator.create_from_bundled_source!(name: DEFAULT_AGENT_NAME, bundled_agent_key: DEFAULT_BUNDLED_AGENT_KEY)
      Agents::WorkspaceInitializer.initialize!(agent: agent)
      activate_runtime!(
        agent: agent,
        endpoint_url: runtime_config.fetch(:endpoint_url),
        fingerprint: runtime_config.fetch(:fingerprint),
        bearer: runtime_config.fetch(:bearer),
        protocol_version: runtime_config.fetch(:protocol_version),
      )
    end

    def bootstrap!
      ensure_agent!
    end

    private

      def activate_runtime!(agent:, endpoint_url:, fingerprint:, bearer:, protocol_version:)
        activated_at = Time.current.change(usec: 0)

        agent.update!(
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: bearer,
          deployment_fingerprint: fingerprint,
          protocol_version: protocol_version,
        )

        # Bootstrap runs before the row qualifies as an active runtime binding,
        # so the RPC client must target the pending deployment record directly.
        initialize_result = Agents::RPCClient.new(agent: agent, deployment: agent).call("initialize")
        identity = initialize_result.fetch("identity", {}).deep_stringify_keys

        agent.update!(
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: bearer,
          deployment_fingerprint: fingerprint,
          status: "active",
          health_status: "healthy",
          protocol_version: identity.fetch("protocol_version", protocol_version),
          supported_methods: Array(identity["supported_methods"]),
          agent_sdk_version: identity["agent_sdk_version"].to_s.presence || agent.agent_sdk_version,
          activated_at: activated_at,
          deactivated_at: nil,
          last_health_checked_at: activated_at,
          last_inspected_at: activated_at,
        )
        Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: agent)
        agent.reload
      rescue StandardError
        agent.update(
          status: "inactive",
          health_status: "unknown",
          deactivated_at: Time.current.change(usec: 0),
        )
        raise
      end
  end
end
