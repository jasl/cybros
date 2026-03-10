require "json"
require "net/http"
require "optparse"
require "uri"
require "webrick"

module Cybros
  module BundledAgentHost
    class Application
      class Servlet < WEBrick::HTTPServlet::AbstractServlet
        def initialize(server, host_application)
          super(server)
          @host_application = host_application
        end

        def do_GET(req, res) = @host_application.handle(req, res)
        def do_POST(req, res) = @host_application.handle(req, res)
      end

      attr_reader :source_root, :host, :port

      def initialize(
        source_root:,
        host: "127.0.0.1",
        port: 0,
        deployment_key: "default",
        deployment_fingerprint: "bundled-default-v1",
        required_bearer: nil
      )
        @source_root = Pathname.new(source_root.to_s)
        @host = host
        @port = Integer(port)
        @deployment_key = deployment_key.to_s
        @deployment_fingerprint = deployment_fingerprint.to_s
        @required_bearer = required_bearer
        @server = nil
        @thread = nil
      end

      def supported_methods
        agent_application.identity.fetch("supported_methods")
      end

      def identity
        agent_application.identity
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

      def rpc_url
        "#{base_url}/rpc"
      end

      def handle(req, res)
        if req.path == "/health"
          write_json(res, router.health_payload)
          return
        end

        router.authorize!(req["Authorization"])
        payload = JSON.parse(req.body.to_s)
        result =
          router.rpc_payload(
            method_name: payload.fetch("method"),
            params: payload.fetch("params", {}),
          )
        write_json(
          res,
          {
            "jsonrpc" => "2.0",
            "id" => payload.fetch("id"),
            "result" => result,
          },
        )
      rescue Router::Unauthorized => e
        write_json(res, error_payload(-32001, e.message), status: 401)
      rescue KeyError => e
        write_json(res, error_payload(-32601, e.message), status: 404)
      rescue JSON::ParserError => e
        write_json(res, error_payload(-32700, e.message), status: 400)
      rescue StandardError => e
        write_json(res, error_payload(-32000, e.message), status: 500)
      end

      private

        attr_reader :deployment_key, :deployment_fingerprint, :required_bearer

        def router
          @router ||= Router.new(agent_application: agent_application, required_bearer: required_bearer)
        end

        def agent_application
          @agent_application ||=
            begin
              lib_root = source_root.join("lib")
              $LOAD_PATH.unshift(lib_root.to_s) unless $LOAD_PATH.include?(lib_root.to_s)
              require "cybros/agents/default"
              Cybros::Agents::Default::Application.new(
                source_root: source_root,
                deployment_key: deployment_key,
                deployment_fingerprint: deployment_fingerprint,
              )
            end
        end

        def bound_port
          @server&.config&.fetch(:Port) || port
        end

        def wait_until_ready!
          40.times do
            return if endpoint_ready?

            sleep 0.05
          end

          raise "bundled agent host did not become ready"
        end

        def endpoint_ready?
          Net::HTTP.get_response(URI("#{base_url}/health")).is_a?(Net::HTTPSuccess)
        rescue StandardError
          false
        end

        def error_payload(code, message)
          {
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => { "code" => code, "message" => message },
          }
        end

        def write_json(res, body, status: 200)
          res.status = status
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(body)
        end
    end

    class CLI
      def self.run(argv)
        options = {
          host: "127.0.0.1",
          port: 4321,
          source_root: Rails.root.join("agents", "default").to_s,
          deployment_key: "default",
          deployment_fingerprint: "bundled-default-v1",
          required_bearer: nil,
        }

        OptionParser.new do |parser|
          parser.on("--host HOST") { |value| options[:host] = value }
          parser.on("--port PORT") { |value| options[:port] = Integer(value) }
          parser.on("--source-root PATH") { |value| options[:source_root] = value }
          parser.on("--deployment-key KEY") { |value| options[:deployment_key] = value }
          parser.on("--deployment-fingerprint FINGERPRINT") { |value| options[:deployment_fingerprint] = value }
          parser.on("--bearer TOKEN") { |value| options[:required_bearer] = value }
        end.parse!(argv)

        application =
          Application.new(
            source_root: options[:source_root],
            host: options[:host],
            port: options[:port],
            deployment_key: options[:deployment_key],
            deployment_fingerprint: options[:deployment_fingerprint],
            required_bearer: options[:required_bearer],
          ).start

        puts "bundled default agent host listening on #{application.rpc_url}"

        Signal.trap("INT") { application.shutdown; exit 0 }
        Signal.trap("TERM") { application.shutdown; exit 0 }

        sleep
      ensure
        application&.shutdown
      end
    end
  end
end
