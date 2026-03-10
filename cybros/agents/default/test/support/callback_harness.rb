require "json"
require "net/http"
require "securerandom"
require "uri"
require "webrick"

module TestSupport
  class CallbackHarness
    class Servlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize(server, harness)
        super(server)
        @harness = harness
      end

      def do_POST(req, res)
        @harness.handle(req, res)
      end
    end

    attr_reader :calls, :required_bearer, :targets

    def initialize(required_bearer: "secret://callback", proposal_decision: "confirm", targets: nil)
      @required_bearer = required_bearer
      @proposal_decision = proposal_decision
      @targets =
        Array(targets || default_targets).map do |target|
          deep_copy(target)
        end
      @calls = []
      @server = nil
      @thread = nil
    end

    def start
      return self if @server

      @server =
        WEBrick::HTTPServer.new(
          Port: 0,
          BindAddress: "127.0.0.1",
          Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
          AccessLog: []
        )
      @server.mount "/rpc", Servlet, self
      @thread = Thread.new { @server.start }
      wait_until_ready!
      @calls.clear
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
      "http://127.0.0.1:#{bound_port}/rpc"
    end

    def received(method_name)
      @calls.select { |call| call.fetch("method") == method_name.to_s }
    end

    def handle(req, res)
      ensure_authorized!(req)

      payload = JSON.parse(req.body.to_s)
      method_name = payload.fetch("method").to_s
      params = normalize_hash(payload.fetch("params", {}))
      @calls << { "method" => method_name, "params" => deep_copy(params) }

      write_json(
        res,
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => result_for(method_name, params),
        }
      )
    rescue KeyError => e
      write_json(res, jsonrpc_error(code: -32_600, message: e.message), status: 400)
    rescue StandardError => e
      write_json(res, jsonrpc_error(code: -32_000, message: e.message), status: 500)
    end

    private

    def result_for(method_name, params)
      case method_name
      when "conversation.settings.update", "conversation.config.update"
        { "status" => "staged", "operation_id" => params["operation_id"] }
      when "lane.kv.set", "lane.kv.delete"
        { "status" => "staged", "operation_id" => params["operation_id"] }
      when "lane.kv.get"
        { "value" => nil }
      when "lane.kv.list"
        { "entries" => [] }
      when "execution_target.list"
        { "targets" => deep_copy(targets) }
      when "execution_target.get"
        { "target" => deep_copy(targets.find { |target| target["id"] == params["execution_target_id"] }) }
      when "execution_target.propose"
        {
          "switch_decision" => {
            "decision" => @proposal_decision,
            "execution_target_id" => params["execution_target_id"],
          },
        }
      else
        raise KeyError, "unsupported callback method: #{method_name}"
      end
    end

    def jsonrpc_error(code:, message:)
      {
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => {
          "code" => code,
          "message" => message,
        },
      }
    end

    def ensure_authorized!(req)
      header = req["Authorization"].to_s
      return if header == "Bearer #{required_bearer}"

      raise "invalid bearer"
    end

    def write_json(res, body, status: 200)
      res.status = status
      res["Content-Type"] = "application/json"
      res.body = JSON.generate(body)
    end

    def wait_until_ready!
      40.times do
        return if ready?

        sleep 0.05
      end

      raise "callback harness did not become ready"
    end

    def ready?
      uri = URI(rpc_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{required_bearer}"
      request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => SecureRandom.uuid,
                                     "method" => "lane.kv.list", "params" => {} })

      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    def bound_port
      @server&.config&.fetch(:Port)
    end

    def default_targets
      [
        {
          "id" => "target-primary",
          "name" => "Project Primary",
          "status" => "active",
          "sandboxed" => true,
        },
        {
          "id" => "target-alternate",
          "name" => "Project Alternate",
          "status" => "active",
          "sandboxed" => true,
        },
      ]
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? deep_copy(value) : {}
    end
  end
end
