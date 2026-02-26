module AgentCore
  module MCP
    # Raised when an MCP server configuration is invalid or inconsistent for the
    # chosen transport. This is a ConfigurationError (and thus a ValidationError).
    class ServerConfigError < AgentCore::ConfigurationError; end
  end
end
