require "set"
require "uri"
require "zlib"

module AgentDeployments
  class EndpointAllocator
    DEFAULT_HOST = "127.0.0.1".freeze
    DEFAULT_RPC_PATH = "/rpc".freeze
    PORT_RANGE = (47_000..47_999).freeze
    ADVISORY_LOCK_KEY = Zlib.crc32("cybros.agent_deployments.endpoint_allocator").freeze

    def allocate!
      lock_allocation!

      port = PORT_RANGE.detect { |candidate| !used_ports.include?(candidate) }
      raise Error, "no managed local deployment ports available" if port.nil?

      {
        "host" => DEFAULT_HOST,
        "port" => port,
        "rpc_path" => DEFAULT_RPC_PATH,
        "endpoint_url" => AgentDeployment.local_endpoint_url(host: DEFAULT_HOST, port: port, rpc_path: DEFAULT_RPC_PATH),
      }
    end

    private

      def lock_allocation!
        AgentDeployment.with_connection do |connection|
          connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
        end
      end

      def used_ports
        @used_ports ||=
          AgentDeployment.find_each.with_object(Set.new) do |deployment, ports|
            port = deployment.allocated_port || local_http_jsonrpc_port(deployment.endpoint_url)
            ports << port if port.present?
          end
      end

      def local_http_jsonrpc_port(endpoint_url)
        uri = URI.parse(endpoint_url.to_s)
        return unless %w[http https].include?(uri.scheme)
        return unless %w[127.0.0.1 localhost].include?(uri.host)

        Integer(uri.port, exception: false)
      rescue URI::InvalidURIError
        nil
      end
  end
end
