require "json"
require "socket"
require "webrick"

module ProgrammableAgentRuntimeTestSupport
  class MockLLMServer
    def self.chat_response(content:, finish_reason: "stop", tool_calls: nil, usage: nil)
      message = { "role" => "assistant", "content" => tool_calls.present? ? nil : content }
      message["tool_calls"] = tool_calls if tool_calls.present?

      {
        status: 200,
        json: {
          "id" => "chatcmpl_fixture",
          "choices" => [
            {
              "index" => 0,
              "message" => message,
              "finish_reason" => finish_reason,
            },
          ],
          "usage" => usage || { "prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5 },
        },
      }
    end

    def self.error_response(status:, message:)
      {
        status: status,
        json: {
          "error" => {
            "message" => message,
          },
        },
      }
    end

    def initialize(host: "127.0.0.1", port: 0, &handler)
      @host = host
      @port = port
      @handler = handler || ->(_payload) { self.class.chat_response(content: "mock llm response") }
    end

    attr_reader :port

    def start
      @server =
        WEBrick::HTTPServer.new(
          BindAddress: @host,
          Port: @port,
          AccessLog: [],
          Logger: WEBrick::Log.new(File::NULL),
        )
      @port = @server.config[:Port]

      @server.mount_proc "/v1/chat/completions" do |req, res|
        payload = parse_json(req.body)
        response = @handler.call(payload) || {}
        status = Integer(response.fetch(:status, 200))
        body = response[:body].to_s
        body = JSON.generate(response[:json]) if body.empty?

        res.status = status
        res["Content-Type"] = "application/json"
        res.body = body
      end

      @thread = Thread.new { @server.start }
      wait_until_ready!
      self
    end

    def base_url
      "http://#{@host}:#{@port}/v1"
    end

    def shutdown
      @server&.shutdown
      @thread&.join(2)
    ensure
      @server = nil
      @thread = nil
    end

    private

      def parse_json(body)
        return {} if body.to_s.strip.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      def wait_until_ready!
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
        loop do
          begin
            socket = TCPSocket.new(@host, @port)
            socket.close
            return
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
            raise "mock llm server failed to start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.01
          end
        end
      end
  end

  def with_catalog_yaml(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "providers.test.yml")
      File.write(path, yaml)

      singleton = Cybros::LLM::Catalog.singleton_class
      singleton.alias_method :__programmable_agent_runtime_test_support_original_resolve_sources, :resolve_sources
      singleton.define_method(:resolve_sources) { [path] }

      begin
        Cybros::LLM::Catalog.reload!
        yield
      ensure
        singleton.alias_method :resolve_sources, :__programmable_agent_runtime_test_support_original_resolve_sources
        singleton.remove_method :__programmable_agent_runtime_test_support_original_resolve_sources
        Cybros::LLM::Catalog.reload!
      end
    end
  end

  def mock_llm_catalog_yaml(base_url:)
    <<~YAML
      version: 1
      default_model_ref: "dev/mock-model"
      providers:
        dev:
          display_name: "Dev"
          enabled: true
          adapter_key: "dev"
          base_url: "#{base_url}"
          headers: {}
          requires_credential: false
          wire_api: "chat_completions"
          transport: "http"
          models:
            mock-model:
              display_name: "Mock"
              api_model: "mock-model"
              context_window_tokens: 20000
              capabilities:
                input: { text: true, image: false }
                tools: { tool_calling: true }
                protocol: "chat_completions"
    YAML
  end
end
