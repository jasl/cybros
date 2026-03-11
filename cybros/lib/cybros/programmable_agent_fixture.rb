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
            capabilities.handshake
            capabilities.refresh
            before_agent_step
            on_context_pressure
            before_subagent_spawn
            before_finalize_output
            after_task_notice
            after_subagent_result
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
      when "capabilities.handshake"
        capabilities_handshake_result(params)
      when "capabilities.refresh"
        capabilities_refresh_result(params)
      when "before_agent_step"
        conversation_id = params["conversation_id"]
        user_input = params["user_input"].to_s.strip

        result = {
          "planning" => {
            "step_plan" => {
              "fixture" => true,
              "kind" => "fixture_plan_v2",
              "conversation_id" => conversation_id,
              "summary" => user_input.empty? ? "fixture planning summary" : "fixture planning summary for #{user_input}",
            },
            "tool_surface" => default_tool_surface(params),
            "staged_mutations" => {},
            "planned_tasks" => [],
          },
        }
        apply_before_agent_step_scenarios!(params, result)
      when "before_finalize_output"
        {
          "actions" => [
            {
              "type" => "emit_message",
              "message" => {
                "role" => "assistant",
                "content" => params.dig("draft_output", "content").to_s.presence || "fixture finalized response",
              },
            },
          ],
        }
      when "on_context_pressure"
        {
          "actions" => [
            {
              "type" => "set_step_status",
              "text" => "Handling context pressure | Action: #{params.dig("context_pressure", "budget_action")}",
            },
          ],
        }
      when "before_subagent_spawn"
        {
          "actions" => [
            {
              "type" => "set_step_status",
              "text" => "Preparing delegated subagent work | Tool: #{params.dig("subagent_request", "tool_name")}",
            },
          ],
        }
      when "after_task_notice"
        {
          "actions" => [
            {
              "type" => "emit_message",
              "message" => {
                "role" => "assistant",
                "content" => "fixture runtime error response",
              },
            },
          ],
        }
      when "after_subagent_result"
        {
          "actions" => [
            {
              "type" => "set_step_status",
              "text" => "Summarizing subagent results | Subagent: #{params.dig("subagent_result", "subagent_id")}",
            },
          ],
        }
      else
        raise KeyError, "unsupported fixture RPC method: #{method_name}"
      end
    end

    def capabilities_handshake_result(params)
      current_version = "fixture-agent-capabilities:v1"
      cached_version = params["cached_agent_capabilities_version"].to_s

      if cached_version == current_version
        {
          "status" => "unchanged",
          "agent_capabilities_version" => current_version,
        }
      else
        {
          "status" => "refreshed",
          "agent_capabilities_version" => current_version,
          "agent_tool_catalog" => [],
        }
      end
    end

    def capabilities_refresh_result(params)
      {
        "status" => "refreshed",
        "refresh_reason" => params["reason"].to_s,
        "agent_capabilities_version" => "fixture-agent-capabilities:v1",
        "agent_tool_catalog" => [],
      }
    end

    def apply_before_agent_step_scenarios!(params, result)
      tokens = scenario_tokens(params["user_input"])
      callback_session = params["callback_session"].is_a?(Hash) ? params["callback_session"] : {}
      result.dig("planning", "step_plan")["fixture_scenarios"] = tokens if tokens.any?

      if tokens.include?("stage-state")
        result["planning"]["staged_mutations"] = {
          "public_settings_patch" => { "tone" => "concise" },
          "agent_config_patch" => { "mode" => "review" },
          "kv_ops" => [
            {
              "op" => "set",
              "key" => "shared.fixture.plan",
              "value" => { "status" => "planned" },
            },
          ],
        }
      end

      if tokens.include?("replay-kv")
        result["planning"]["staged_mutations"] ||= {}
        result["planning"]["staged_mutations"]["kv_ops"] = [
          {
            "op" => "set",
            "key" => "shared.fixture.replay",
            "value" => { "status" => "deduped" },
          },
          {
            "op" => "set",
            "key" => "shared.fixture.replay",
            "value" => { "status" => "deduped" },
          },
        ]
      end

      if tokens.include?("switch-target")
        targets = callback_rpc(callback_session, "execution_target.list", {}).fetch("targets", [])
        current_target_id = params["execution_target_id"].to_s
        alternate_target =
          paired_target_for(targets: targets, current_target_id: current_target_id) ||
          targets.find { |target| target["id"].to_s != current_target_id }

        unless alternate_target.nil?
          proposal =
            callback_rpc(
              callback_session,
              "execution_target.propose",
              {
                "operation_id" => "fixture-target-switch",
                "execution_target_id" => alternate_target.fetch("id"),
              },
            )
          if proposal.dig("switch_decision", "decision").to_s == "confirm"
            result["planning"]["approval_request"] = {
              "status" => "pending_confirmation",
              "reason" => "target_switch",
              "proposed_execution_target_id" => alternate_target.fetch("id"),
            }
          end
        end
      end

      if tokens.include?("approval")
        result["planning"]["approval_request"] ||= {
          "status" => "pending_confirmation",
          "reason" => "fixture_approval",
        }
      end

      result
    end

    def default_tool_surface(params)
      snapshot = params["capability_snapshot"].is_a?(Hash) ? deep_copy(params["capability_snapshot"]) : {}
      snapshot_id = snapshot["capability_registry_snapshot_id"].to_s.strip
      selected_tool_ids =
        Array(snapshot["effective_tools"]).filter_map do |tool|
          next unless tool.is_a?(Hash)

          effective_tool_id = tool["effective_tool_id"].to_s.strip
          effective_tool_id unless effective_tool_id.empty?
        end.uniq
      return nil if snapshot_id.empty? || selected_tool_ids.empty?

      {
        "capability_registry_snapshot_id" => snapshot_id,
        "selected_tool_ids" => selected_tool_ids,
        "tool_surface_label" => "fixture.before_agent_step",
      }
    end

    def scenario_tokens(user_input)
      user_input.to_s.scan(/\[fixture:([a-z0-9_-]+)\]/i).flatten.map(&:downcase)
    end

    def paired_target_for(targets:, current_target_id:)
      current_target = targets.find { |target| target["id"].to_s == current_target_id.to_s }
      return nil if current_target.nil?

      current_name = current_target["name"].to_s
      paired_name =
        if current_name.end_with?(" Primary")
          "#{current_name.delete_suffix(" Primary")} Alternate"
        elsif current_name.end_with?(" Alternate")
          "#{current_name.delete_suffix(" Alternate")} Primary"
        end

      return nil if paired_name.nil? || paired_name.empty?

      targets.find do |target|
        target["id"].to_s != current_target_id.to_s && target["name"].to_s == paired_name
      end
    end

    def callback_rpc(callback_session, method_name, params)
      endpoint = callback_session.fetch("endpoint")
      bearer = callback_session.fetch("bearer")
      uri = URI(endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{bearer}"
      request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => method_name, "params" => params })

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      raise "callback #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      if payload.key?("error") && !payload["error"].nil?
        raise "callback error: #{payload.fetch("error").inspect}"
      end

      payload.fetch("result")
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
        bearer = required_bearer.to_s.strip
        @required_bearer = bearer.empty? ? nil : bearer
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
      rescue StandardError => e
        write_json(res, { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32000, "message" => e.message } }, status: 500)
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
          return if @required_bearer.nil? || @required_bearer.empty?

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
