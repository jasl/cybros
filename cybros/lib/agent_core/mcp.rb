# MCP (Model Context Protocol) namespace.
#
# All MCP components are Zeitwerk-autoloaded from `lib/agent_core/mcp/**`.
# Streamable HTTP transport (`Transport::StreamableHttp`) is an optional path
# that loads the `httpx` gem only when referenced.

module AgentCore
  module MCP
    class Error < AgentCore::Error; end
    class TransportError < Error; end
    class ProtocolError < Error; end
    class TimeoutError < Error; end
    class ServerError < Error; end
    class InitializationError < Error; end
    class ClosedError < Error; end
    class ProtocolVersionNotSupportedError < Error; end

    # JSON-RPC error returned by an MCP server.
    class JsonRpcError < Error
      attr_reader :code, :data

      def initialize(code, message, data: nil)
        @code = code
        @data = data
        super(message.to_s)
      end
    end

    module Constants
      DEFAULT_PROTOCOL_VERSION = "2025-11-25"
      SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].freeze
      DEFAULT_TIMEOUT_S = 10.0
      DEFAULT_MAX_BYTES = 200_000

      HTTP_ACCEPT_POST = "application/json, text/event-stream"
      HTTP_ACCEPT_GET = "text/event-stream"

      MCP_SESSION_ID_HEADER = "MCP-Session-Id"
      MCP_PROTOCOL_VERSION_HEADER = "MCP-Protocol-Version"
      LAST_EVENT_ID_HEADER = "Last-Event-ID"
    end

    DEFAULT_PROTOCOL_VERSION = Constants::DEFAULT_PROTOCOL_VERSION
    SUPPORTED_PROTOCOL_VERSIONS = Constants::SUPPORTED_PROTOCOL_VERSIONS
    DEFAULT_TIMEOUT_S = Constants::DEFAULT_TIMEOUT_S
    DEFAULT_MAX_BYTES = Constants::DEFAULT_MAX_BYTES

    HTTP_ACCEPT_POST = Constants::HTTP_ACCEPT_POST
    HTTP_ACCEPT_GET = Constants::HTTP_ACCEPT_GET

    MCP_SESSION_ID_HEADER = Constants::MCP_SESSION_ID_HEADER
    MCP_PROTOCOL_VERSION_HEADER = Constants::MCP_PROTOCOL_VERSION_HEADER
    LAST_EVENT_ID_HEADER = Constants::LAST_EVENT_ID_HEADER
  end
end
