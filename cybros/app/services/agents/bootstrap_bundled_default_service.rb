module Agents
  class BootstrapBundledDefaultService
    DEFAULT_BUNDLED_AGENT_KEY = "claw".freeze
    DEFAULT_AGENT_NAME = "Claw".freeze
    DEFAULT_DEPLOYMENT_FINGERPRINT = "deployment:bundled-claw:managed-local".freeze
    DEFAULT_DEPLOYMENT_BEARER = "secret://bundled-claw:managed-local".freeze
    TEST_DEPLOYMENT_FINGERPRINT = "deployment:bundled-claw:test".freeze
    TEST_DEPLOYMENT_BEARER = "secret://bundled-claw:test".freeze
    PROTOCOL_VERSION = "agent_rpc.v1".freeze
    HOST_MUTEX = Mutex.new

    class << self
      def ensure_agent!
        new.ensure_agent!
      end

      def bootstrap!
        new.bootstrap!
      end

      def ensure_test_runtime!
        return unless Rails.env.test?

        new.ensure_test_runtime!
      end
    end

    def ensure_agent!
      agent = Agents::Creator.create_from_bundled_source!(name: DEFAULT_AGENT_NAME, bundled_agent_key: DEFAULT_BUNDLED_AGENT_KEY)
      Agents::WorkspaceInitializer.initialize!(agent: agent)
      activate_runtime!(agent: agent, fingerprint: deployment_fingerprint, bearer: deployment_bearer)
    end

    def bootstrap!
      ensure_agent!
    end

    def ensure_test_runtime!
      ensure_agent!
    end

    private

      def activate_runtime!(agent:, fingerprint:, bearer:)
        host = ensure_host!(agent: agent, fingerprint: fingerprint, bearer: bearer)
        activated_at = Time.current.change(usec: 0)

        agent.update!(
          transport_kind: "http_jsonrpc",
          endpoint_url: host.rpc_url,
          deployment_bearer_secret_ref: bearer,
          deployment_fingerprint: fingerprint,
          status: "active",
          health_status: "healthy",
          protocol_version: PROTOCOL_VERSION,
          supported_methods: Array(host.supported_methods),
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

      def ensure_host!(agent:, fingerprint:, bearer:)
        HOST_MUTEX.synchronize do
          key = [Rails.env, agent.bundled_agent_key.to_s]
          hosts = self.class.instance_variable_get(:@hosts) || self.class.instance_variable_set(:@hosts, {})
          existing = hosts[key]
          if existing.present?
            same_source = existing.source_root.to_s == agent.absolute_local_path.to_s
            same_fingerprint = existing.identity.fetch("deployment_fingerprint", nil).to_s == fingerprint.to_s
            same_workspace_root = existing.workspace_root.to_s == agent.workspace_root_path.to_s
            return existing if same_source && same_fingerprint && same_workspace_root

            existing.shutdown
            hosts.delete(key)
          end

          host =
            Cybros::BundledAgentHost::Application.new(
              source_root: agent.absolute_local_path,
              workspace_root: agent.workspace_root_path,
              deployment_key: agent.bundled_agent_key.to_s.presence || DEFAULT_BUNDLED_AGENT_KEY,
              deployment_fingerprint: fingerprint,
              required_bearer: bearer,
            ).start
          hosts[key] = host
        end
      end

      def deployment_fingerprint
        Rails.env.test? ? TEST_DEPLOYMENT_FINGERPRINT : DEFAULT_DEPLOYMENT_FINGERPRINT
      end

      def deployment_bearer
        Rails.env.test? ? TEST_DEPLOYMENT_BEARER : DEFAULT_DEPLOYMENT_BEARER
      end
  end
end
