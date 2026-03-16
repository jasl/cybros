require "json"
require "net/http"
require "uri"
require "webrick"

module TestSupport
  class BundledClawRuntimeServer
    class Unauthorized < StandardError; end

    class Servlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize(server, runtime_server)
        super(server)
        @runtime_server = runtime_server
      end

      def do_GET(req, res) = @runtime_server.handle(req, res)
      def do_POST(req, res) = @runtime_server.handle(req, res)
    end

    attr_reader :host, :port, :source_root

    def initialize(source_root:, host: "127.0.0.1", port: 0, workspace_root: nil, deployment_fingerprint:, required_bearer:)
      @source_root = Pathname.new(source_root.to_s)
      @host = host
      @port = Integer(port)
      @mutex = Mutex.new
      @server = nil
      @thread = nil
      ensure_claw_library_loaded!
      reconfigure!(workspace_root:, deployment_fingerprint:, required_bearer:)
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

    def reconfigure!(workspace_root:, deployment_fingerprint:, required_bearer:)
      @mutex.synchronize do
        @workspace_root = workspace_root.present? ? Pathname.new(workspace_root.to_s) : nil
        @deployment_fingerprint = deployment_fingerprint.to_s
        @required_bearer = required_bearer.to_s
      end
    end

    def config_snapshot
      @mutex.synchronize do
        {
          workspace_root: @workspace_root,
          deployment_fingerprint: @deployment_fingerprint,
          required_bearer: @required_bearer,
        }
      end
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

    def handle(req, res)
      if req.path == "/health"
        write_json(
          res,
          {
            "ok" => true,
            "status" => "healthy",
            "identity" => application.identity,
          },
        )
        return
      end

      authorize!(req["Authorization"])
      payload = JSON.parse(req.body.to_s)
      result = application.call(method_name: payload.fetch("method"), params: payload.fetch("params", {}))

      write_json(
        res,
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => result,
        },
      )
    rescue Unauthorized => error
      write_json(res, error_payload(-32_000, error.message), status: 500)
    rescue KeyError => error
      write_json(res, error_payload(-32_601, error.message), status: 404)
    rescue JSON::ParserError => error
      write_json(res, error_payload(-32_700, error.message), status: 400)
    rescue StandardError => error
      write_json(res, error_payload(-32_000, error.message), status: 500)
    end

    private

      def application
        snapshot = config_snapshot

        Cybros::Agents::Claw::Application.new(
          source_root: source_root,
          workspace_root: snapshot.fetch(:workspace_root),
          deployment_fingerprint: snapshot.fetch(:deployment_fingerprint),
          required_bearer: snapshot.fetch(:required_bearer),
        )
      end

      def authorize!(authorization_header)
        required_bearer = config_snapshot.fetch(:required_bearer).to_s
        return if required_bearer.blank?
        return if authorization_header.to_s == "Bearer #{required_bearer}"

        raise Unauthorized, "invalid bearer"
      end

      def ensure_claw_library_loaded!
        lib_root = source_root.join("lib")
        $LOAD_PATH.unshift(lib_root.to_s) unless $LOAD_PATH.include?(lib_root.to_s)
        require "cybros/agents/claw"
      end

      def wait_until_ready!
        40.times do
          return if endpoint_ready?

          sleep 0.05
        end

        raise "bundled claw runtime fixture did not become ready"
      end

      def endpoint_ready?
        Net::HTTP.get_response(URI(health_url)).is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      def bound_port
        @server&.config&.fetch(:Port) || port
      end

      def error_payload(code, message)
        {
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => {
            "code" => code,
            "message" => message,
          },
        }
      end

      def write_json(res, body, status: 200)
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(body)
      end
  end
end
