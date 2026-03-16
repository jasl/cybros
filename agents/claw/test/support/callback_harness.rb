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

    attr_reader :calls, :required_bearer, :targets, :prompt_buffer_entries

    def initialize(required_bearer: "secret://callback", proposal_decision: "confirm", targets: nil, prompt_buffer_entries: nil, memory_document: "", memory_documents: nil)
      @required_bearer = required_bearer
      @proposal_decision = proposal_decision
      @targets =
        Array(targets || default_targets).map do |target|
          deep_copy(target)
        end
      @prompt_buffer_entries =
        Array(prompt_buffer_entries).map do |entry|
          deep_copy(entry)
        end
      @memory_documents = normalize_memory_documents(memory_document: memory_document, memory_documents: memory_documents)
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
          "result" => result_for(method_name, params)
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
      when "conversation.memory.get"
        memory_result(params)
      when "conversation.memory.put"
        @memory_documents[memory_key_for(params)] = params.fetch("body", params["content"]).to_s
        memory_result(params)
      when "conversation.memory.append"
        key = memory_key_for(params)
        @memory_documents[key] = @memory_documents.fetch(key, "") + params.fetch("text", params["content"]).to_s
        memory_result(params)
      when "lane.kv.set", "lane.kv.delete"
        { "status" => "staged", "operation_id" => params["operation_id"] }
      when "lane.kv.get"
        { "value" => nil }
      when "lane.kv.list"
        { "entries" => [] }
      when "lane.prompt_buffer.list", "lane.prompt_buffer.snapshot"
        buffer_name = params["buffer_name"].to_s.strip
        entries = deep_copy(prompt_buffer_entries)
        unless buffer_name.empty?
          entries.select! { |entry| entry["buffer_name"].to_s == buffer_name }
        end
        { "entries" => entries }
      when "execution_target.list"
        { "targets" => deep_copy(targets) }
      when "execution_target.get"
        { "target" => deep_copy(targets.find { |target| target["id"] == params["execution_target_id"] }) }
      when "execution_target.propose"
        {
          "switch_decision" => {
            "decision" => @proposal_decision,
            "execution_target_id" => params["execution_target_id"]
          }
        }
      when "tool_surface.manifest"
        {
          "capability_registry_snapshot_id" => params["capability_registry_snapshot_id"],
          "selected_tool_ids" => Array(params["selected_tool_ids"]),
          "tool_surface_id" => "surface_callback_harness",
          "logical_tool_names" => []
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
          "message" => message
        }
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
          "sandboxed" => true
        },
        {
          "id" => "target-alternate",
          "name" => "Project Alternate",
          "status" => "active",
          "sandboxed" => true
        }
      ]
    end

    def memory_result(params)
      scope, target = memory_key_for(params)

      {
        "document" => {
          "kind" => "workspace_memory",
          "scope" => scope,
          "target" => target,
          "path" => "/memory/#{scope}/#{target}",
          "body" => @memory_documents.fetch([scope, target], ""),
          "materialized" => @memory_documents.key?([scope, target]),
        }
      }
    end

    def memory_key_for(params)
      [params["scope"].to_s.presence || "conversation", params["target"].to_s.presence || "MEMORY.md"]
    end

    def normalize_memory_documents(memory_document:, memory_documents:)
      if memory_documents.is_a?(Hash)
        return memory_documents.each_with_object({}) do |(key, value), out|
          scope, target = Array(key)
          out[[scope.to_s, target.to_s]] = value.to_s
        end
      end

      { ["conversation", "MEMORY.md"] => memory_document.to_s }
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? deep_copy(value) : {}
    end
  end
end
