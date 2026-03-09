require "json"
require "net/http"
require "optparse"
require "uri"
require "webrick"

module Cybros
  module ProgrammableAgentFixture
    module_function

    def identity(overrides = nil)
      base =
        {
          "agent_program_key" => "fixture-program",
          "agent_deployment_key" => "fixture-deployment",
          "deployment_fingerprint" => "fixture-deployment-v1",
          "protocol_version" => "agent_rpc.v1",
          "agent_sdk_version" => "fixture-ruby-sdk/1.0",
          "supported_methods" => %w[
            initialize
            agent.describe
            agent.health
            agent.schemas.get
            turn.prepare
            turn.compose
          ],
        }

      deep_merge(base, overrides || {})
    end

    def deep_copy(object)
      JSON.parse(JSON.generate(object))
    end

    def deep_merge(base, override)
      base_hash = deep_copy(base)
      override_hash = deep_copy(override)

      merge_values(base_hash, override_hash)
    end

    def merge_values(base_value, override_value)
      return deep_copy(override_value) unless base_value.is_a?(Hash) && override_value.is_a?(Hash)

      base_value.merge(override_value) do |_key, existing, replacement|
        merge_values(existing, replacement)
      end
    end

    def rpc_result(method_name, params = {}, identity: nil)
      identity ||= self.identity

      case method_name.to_s
      when "initialize"
        {
          "identity" => identity,
          "agent" => {
            "key" => "fixture-programmable-agent",
            "name" => "Fixture Programmable Agent",
          },
          "deployment" => {
            "key" => "fixture-deployment",
            "fingerprint" => "fixture-deployment-v1",
          },
        }
      when "agent.describe"
        {
          "name" => "Fixture Programmable Agent",
          "description" => "Reference fixture for programmable-agent integration tests.",
          "identity" => identity,
        }
      when "agent.health"
        {
          "healthy" => true,
          "status" => "healthy",
          "identity" => identity,
        }
      when "agent.schemas.get"
        {
          "global_config_schema" => { "type" => "object", "properties" => {} },
          "conversation_config_schema" => { "type" => "object", "properties" => {} },
        }
      when "turn.prepare"
        conversation_id = params["conversation_id"]
        user_input = params["user_input"].to_s.strip

        {
          "prepared_plan" => {
            "fixture" => true,
            "kind" => "fixture_plan_v1",
            "conversation_id" => conversation_id,
            "summary" => user_input.empty? ? "fixture prepare plan" : "fixture prepare plan for #{user_input}",
          },
          "prompt_fragments" => [
            {
              "role" => "system",
              "content" => "fixture prepare fragment",
            },
          ],
        }
      when "turn.compose"
        {
          "output" => {
            "role" => "assistant",
            "content" => "fixture compose response",
          },
        }
      else
        raise KeyError, "unsupported fixture RPC method: #{method_name}"
      end
    end

    class Server
      class Servlet < WEBrick::HTTPServlet::AbstractServlet
        def initialize(server, fixture_server)
          super(server)
          @fixture_server = fixture_server
        end

        def do_GET(req, res) = @fixture_server.handle(req, res)
        def do_POST(req, res) = @fixture_server.handle(req, res)
      end

      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 0, identity_overrides: {}, rpc_overrides: {}, required_bearer: nil)
        @host = host
        @port = Integer(port)
        @identity_overrides = ProgrammableAgentFixture.deep_copy(identity_overrides)
        @rpc_overrides = rpc_overrides
        @required_bearer = required_bearer.to_s.presence
        @server = nil
        @thread = nil
      end

      def start
        return self if @server

        @server =
          WEBrick::HTTPServer.new(
            Port: port,
            BindAddress: host,
            Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
            AccessLog: [],
          )
        @server.mount "/health", Servlet, self
        @server.mount "/rpc", Servlet, self
        @thread = Thread.new { @server.start }
        wait_until_ready!
        self
      end

      def shutdown
        return unless @server

        @server.shutdown
        @thread&.join(1.0)
      ensure
        @server = nil
        @thread = nil
      end

      def base_url
        "http://#{host}:#{bound_port}"
      end

      def health_url
        "#{base_url}/health"
      end

      def rpc_url
        "#{base_url}/rpc"
      end

      def rpc_call(method_name, params = {})
        uri = URI(rpc_url)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => method_name, "params" => params })

        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        payload = JSON.parse(response.body)
        payload.fetch("result")
      end

      def handle(req, res)
        if req.path == "/health"
          write_json(
            res,
            {
              "ok" => true,
              "status" => "healthy",
              "identity" => fixture_identity,
              "deployment" => {
                "key" => "fixture-deployment",
                "fingerprint" => fixture_identity.fetch("deployment_fingerprint"),
              },
            },
          )
          return
        end

        ensure_authorized!(req)

        payload = JSON.parse(req.body.to_s)
        result = fixture_rpc_result(payload.fetch("method"), payload.fetch("params", {}))
        write_json(
          res,
          {
            "jsonrpc" => "2.0",
            "id" => payload.fetch("id"),
            "result" => result,
          },
        )
      rescue KeyError => e
        write_json(res, { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32601, "message" => e.message } }, status: 404)
      rescue Unauthorized => e
        write_json(res, { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32001, "message" => e.message } }, status: 401)
      rescue JSON::ParserError => e
        write_json(res, { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32700, "message" => e.message } }, status: 400)
      end

      private

        Unauthorized = Class.new(StandardError)

        def bound_port
          @server&.config&.fetch(:Port) || port
        end

        def wait_until_ready!
          40.times do
            return if endpoint_ready?

            sleep 0.05
          end

          raise "programmable-agent fixture did not become ready"
        end

        def endpoint_ready?
          Net::HTTP.get_response(URI(health_url)).is_a?(Net::HTTPSuccess)
        rescue StandardError
          false
        end

        def write_json(res, body, status: 200)
          res.status = status
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(body)
        end

        def fixture_identity
          @fixture_identity ||= ProgrammableAgentFixture.identity(@identity_overrides)
        end

        def ensure_authorized!(req)
          return if @required_bearer.blank?

          header = req["Authorization"].to_s
          return if header == "Bearer #{@required_bearer}"

          raise Unauthorized, "invalid bearer"
        end

        def fixture_rpc_result(method_name, params)
          base_result = ProgrammableAgentFixture.rpc_result(method_name, params, identity: fixture_identity)
          override = @rpc_overrides[method_name.to_s]

          case override
          when Proc
            override.call(params, base_result, fixture_identity)
          when Hash
            ProgrammableAgentFixture.deep_merge(base_result, override)
          when nil
            base_result
          else
            override
          end
        end
    end

    class CLI
      def self.run(argv)
        options = {
          host: "127.0.0.1",
          port: 4319,
        }

        OptionParser.new do |parser|
          parser.on("--host HOST") { |value| options[:host] = value }
          parser.on("--port PORT") { |value| options[:port] = Integer(value) }
        end.parse!(argv)

        server = Server.new(host: options[:host], port: options[:port]).start
        puts "programmable-agent fixture listening on #{server.rpc_url}"

        Signal.trap("INT") { server.shutdown; exit 0 }
        Signal.trap("TERM") { server.shutdown; exit 0 }

        sleep
      ensure
        server&.shutdown
      end
    end
  end
end
