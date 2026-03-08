require "test_helper"

class AgentCore::Resources::Tools::ToolFailureTaxonomyTest < ActiveSupport::TestCase
  class FakeHttpError < StandardError
    attr_reader :status

    def initialize(message, status:)
      @status = status
      super(message)
    end
  end

  class FakeMcpClient
    def initialize(error:)
      @error = error
    end

    def list_tools(cursor: nil)
      _ = cursor
      {
        "tools" => [
          {
            "name" => "echo",
            "description" => "Echo",
            "inputSchema" => {
              "type" => "object",
              "additionalProperties" => false,
              "properties" => { "text" => { "type" => "string" } },
            },
          },
        ],
      }
    end

    def call_tool(name:, arguments:)
      _ = name
      _ = arguments
      raise @error
    end
  end

  test "native validation failures map to validation_error with tool_execution metadata" do
    tool =
      AgentCore::Resources::Tools::Tool.new(
        name: "validate_me",
        description: "Validate",
        parameters: { type: "object" },
      ) do |_args, **|
        AgentCore::ValidationError.raise!(
          "bad input",
          code: "tool.invalid_input",
          details: { "field" => "text" },
        )
      end

    result = tool.call({})

    assert result.error?
    assert_equal "validation_error", result.metadata.dig("tool_execution", "failure_class")
    assert_equal "tool.invalid_input", result.metadata.dig("tool_execution", "failure_code")
    assert_equal false, result.metadata.dig("tool_execution", "retryable")
    assert_equal "tool.invalid_input", result.metadata.dig("validation_error", "code")
  end

  test "uncaught native tool exceptions map to implementation_error" do
    tool =
      AgentCore::Resources::Tools::Tool.new(
        name: "explode",
        description: "Explode",
        parameters: { type: "object" },
      ) do |_args, **|
        raise StandardError, "boom"
      end

    result = tool.call({})

    assert result.error?
    assert_equal "implementation_error", result.metadata.dig("tool_execution", "failure_class")
    assert_equal false, result.metadata.dig("tool_execution", "retryable")
  end

  test "mcp transport failures map to remote_api_error" do
    registry = AgentCore::Resources::Tools::Registry.new
    registry.register_mcp_client(FakeMcpClient.new(error: AgentCore::MCP::TransportError.new("transport down")))

    result = registry.execute(name: "echo", arguments: {})

    assert result.error?
    assert_equal "remote_api_error", result.metadata.dig("tool_execution", "failure_class")
    assert_equal "mcp_transport_error", result.metadata.dig("tool_execution", "failure_code")
    assert_equal true, result.metadata.dig("tool_execution", "retryable")
  end

  test "timeout rate-limit and auth errors classify distinctly when recognizable" do
    timeout_tool =
      AgentCore::Resources::Tools::Tool.new(
        name: "timeout_tool",
        description: "Timeout",
        parameters: { type: "object" },
      ) do |_args, **|
        raise Timeout::Error, "execution expired"
      end

    rate_limit_tool =
      AgentCore::Resources::Tools::Tool.new(
        name: "rate_limit_tool",
        description: "Rate limit",
        parameters: { type: "object" },
      ) do |_args, **|
        raise FakeHttpError.new("rate limited", status: 429)
      end

    auth_tool =
      AgentCore::Resources::Tools::Tool.new(
        name: "auth_tool",
        description: "Auth",
        parameters: { type: "object" },
      ) do |_args, **|
        raise FakeHttpError.new("unauthorized", status: 401)
      end

    assert_equal "timeout", timeout_tool.call({}).metadata.dig("tool_execution", "failure_class")
    assert_equal "rate_limit", rate_limit_tool.call({}).metadata.dig("tool_execution", "failure_class")
    assert_equal "auth", auth_tool.call({}).metadata.dig("tool_execution", "failure_class")
  end
end
