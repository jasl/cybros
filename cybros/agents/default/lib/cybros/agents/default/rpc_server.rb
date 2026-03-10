module Cybros
  module Agents
    module Default
      class RPCServer
        class Servlet < WEBrick::HTTPServlet::AbstractServlet
          def initialize(server, rpc_server)
            super(server)
            @rpc_server = rpc_server
          end

          def do_GET(req, res)
            @rpc_server.handle(req, res)
          end

          def do_POST(req, res)
            @rpc_server.handle(req, res)
          end
        end

        def initialize(application:, host:, port:, required_bearer: nil)
          @application = application
          @host = host
          @port = Integer(port)
          bearer = required_bearer.to_s.strip
          @required_bearer = bearer.empty? ? nil : bearer
          @server = nil
          @thread = nil
        end

        def start
          return self if @server

          @server =
            WEBrick::HTTPServer.new(
              Port: @port,
              BindAddress: @host,
              Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
              AccessLog: []
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

        def rpc_url
          "http://#{@host}:#{bound_port}/rpc"
        end

        def handle(req, res)
          if req.path == "/health"
            write_json(res, { "ok" => true, "status" => "healthy", "identity" => @application.identity })
            return
          end

          ensure_authorized!(req["Authorization"])
          payload = JSON.parse(req.body.to_s)
          result =
            @application.call(
              method_name: payload.fetch("method"),
              params: payload.fetch("params", {})
            )
          write_json(res, { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => result })
        rescue KeyError => e
          write_json(res, jsonrpc_error(code: -32_601, message: e.message), status: 404)
        rescue JSON::ParserError => e
          write_json(res, jsonrpc_error(code: -32_700, message: e.message), status: 400)
        rescue StandardError => e
          write_json(res, jsonrpc_error(code: -32_000, message: e.message), status: 500)
        end

        private

        def ensure_authorized!(header)
          return if @required_bearer.nil?
          return if header.to_s == "Bearer #{@required_bearer}"

          raise "invalid bearer"
        end

        def wait_until_ready!
          40.times do
            return if ready?

            sleep 0.05
          end

          raise "bundled default RPC server did not become ready"
        end

        def ready?
          uri = URI(rpc_url)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@required_bearer}" if @required_bearer
          request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => "agent.health",
                                         "params" => {} })
          response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
          response.is_a?(Net::HTTPSuccess)
        rescue StandardError
          false
        end

        def bound_port
          @server&.config&.fetch(:Port)
        end

        def jsonrpc_error(code:, message:)
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
    end
  end
end
