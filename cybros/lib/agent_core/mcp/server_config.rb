module AgentCore
  module MCP
    # Immutable configuration for an MCP server connection.
    #
    # Uses Data.define for a frozen, value-equality struct.
    # Transport-specific validation ensures fields are appropriate
    # for the chosen transport type.
    ServerConfig =
      Data.define(
        :id,
        :transport,
        :command,
        :args,
        :env,
        :env_provider,
        :chdir,
        :url,
        :headers,
        :headers_provider,
        :on_stdout_line,
        :on_stderr_line,
        :protocol_version,
        :client_info,
        :capabilities,
        :timeout_s,
        :open_timeout_s,
        :read_timeout_s,
        :sse_max_reconnects,
        :max_response_bytes,
      ) do
        def initialize( # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
          id:,
          transport: nil,
          command: nil,
          args: nil,
          env: nil,
          env_provider: nil,
          chdir: nil,
          url: nil,
          headers: nil,
          headers_provider: nil,
          on_stdout_line: nil,
          on_stderr_line: nil,
          protocol_version: nil,
          client_info: nil,
          capabilities: nil,
          timeout_s: nil,
          open_timeout_s: nil,
          read_timeout_s: nil,
          sse_max_reconnects: nil,
          max_response_bytes: nil
        )
          id = id.to_s.strip
          ServerConfigError.raise!(
            "id is required",
            code: "agent_core.mcp.server_config.id_is_required",
          ) if id.empty?

          transport = normalize_transport(transport)

          command = blank?(command) ? nil : command.to_s.strip
          url = blank?(url) ? nil : url.to_s.strip

          on_stdout_line = normalize_optional_callable(on_stdout_line, field: "on_stdout_line")
          on_stderr_line = normalize_optional_callable(on_stderr_line, field: "on_stderr_line")

          case transport
          when :stdio
            ServerConfigError.raise!(
              "command is required",
              code: "agent_core.mcp.server_config.command_is_required",
            ) if command.nil? || command.empty?
            ServerConfigError.raise!(
              "url must be empty for stdio transport",
              code: "agent_core.mcp.server_config.url_must_be_empty_for_stdio_transport",
            ) if url

            http_headers = normalize_headers(headers)
            ServerConfigError.raise!(
              "headers must be empty for stdio transport",
              code: "agent_core.mcp.server_config.headers_must_be_empty_for_stdio_transport",
              details: { header_count: http_headers&.length.to_i },
            ) if http_headers && !http_headers.empty?
            ServerConfigError.raise!(
              "headers_provider must be empty for stdio transport",
              code: "agent_core.mcp.server_config.headers_provider_must_be_empty_for_stdio_transport",
            ) unless headers_provider.nil?
            ServerConfigError.raise!(
              "open_timeout_s must be empty for stdio transport",
              code: "agent_core.mcp.server_config.open_timeout_s_must_be_empty_for_stdio_transport",
            ) unless open_timeout_s.nil?
            ServerConfigError.raise!(
              "read_timeout_s must be empty for stdio transport",
              code: "agent_core.mcp.server_config.read_timeout_s_must_be_empty_for_stdio_transport",
            ) unless read_timeout_s.nil?
            ServerConfigError.raise!(
              "sse_max_reconnects must be empty for stdio transport",
              code: "agent_core.mcp.server_config.sse_max_reconnects_must_be_empty_for_stdio_transport",
            ) unless sse_max_reconnects.nil?
            ServerConfigError.raise!(
              "max_response_bytes must be empty for stdio transport",
              code: "agent_core.mcp.server_config.max_response_bytes_must_be_empty_for_stdio_transport",
            ) unless max_response_bytes.nil?

            env_provider = normalize_optional_callable(env_provider, field: "env_provider")
          when :streamable_http
            ServerConfigError.raise!(
              "url is required",
              code: "agent_core.mcp.server_config.url_is_required",
            ) if url.nil? || url.empty?
            ServerConfigError.raise!(
              "command must be empty for streamable_http transport",
              code: "agent_core.mcp.server_config.command_must_be_empty_for_streamable_http_transport",
            ) if command
            ServerConfigError.raise!(
              "args must be empty for streamable_http transport",
              code: "agent_core.mcp.server_config.args_must_be_empty_for_streamable_http_transport",
            ) unless Array(args).empty?

            env_hash = normalize_env(env)
            ServerConfigError.raise!(
              "env must be empty for streamable_http transport",
              code: "agent_core.mcp.server_config.env_must_be_empty_for_streamable_http_transport",
              details: { env_keys: env_hash.keys.sort },
            ) unless env_hash.empty?
            ServerConfigError.raise!(
              "env_provider must be empty for streamable_http transport",
              code: "agent_core.mcp.server_config.env_provider_must_be_empty_for_streamable_http_transport",
            ) unless env_provider.nil?
            ServerConfigError.raise!(
              "chdir must be empty for streamable_http transport",
              code: "agent_core.mcp.server_config.chdir_must_be_empty_for_streamable_http_transport",
            ) unless blank?(chdir)

            open_timeout_s = normalize_optional_timeout_s(open_timeout_s, field: "open_timeout_s")
            read_timeout_s = normalize_optional_timeout_s(read_timeout_s, field: "read_timeout_s")
            sse_max_reconnects = normalize_optional_positive_integer(sse_max_reconnects, field: "sse_max_reconnects")
            max_response_bytes = normalize_optional_positive_integer(max_response_bytes, field: "max_response_bytes")

            headers = normalize_headers(headers) || {}
            headers_provider = normalize_optional_callable(headers_provider, field: "headers_provider")
            args = []
            env = {}
            env_provider = nil
            chdir = nil
          else
            ServerConfigError.raise!(
              "unsupported transport: #{transport.inspect}",
              code: "agent_core.mcp.server_config.unsupported_transport",
              details: { transport: transport&.to_s },
            )
          end

          protocol_version = normalize_protocol_version(protocol_version)
          timeout_s = normalize_timeout_s(timeout_s)

          super(
            id: id,
            transport: transport,
            command: command,
            args: Array(args).map(&:to_s),
            env: normalize_env(env),
            env_provider: env_provider,
            chdir: blank?(chdir) ? nil : chdir.to_s,
            url: url,
            headers: headers,
            headers_provider: headers_provider,
            on_stdout_line: on_stdout_line,
            on_stderr_line: on_stderr_line,
            protocol_version: protocol_version,
            client_info: client_info.is_a?(Hash) ? client_info : nil,
            capabilities: capabilities.is_a?(Hash) ? capabilities : {},
            timeout_s: timeout_s,
            open_timeout_s: open_timeout_s,
            read_timeout_s: read_timeout_s,
            sse_max_reconnects: sse_max_reconnects,
            max_response_bytes: max_response_bytes,
          )
        end

        # Coerce a Hash (with symbol keys) into a ServerConfig.
        #
        # @param value [Hash, ServerConfig]
        # @return [ServerConfig]
        def self.coerce(value)
          return value if value.is_a?(AgentCore::MCP::ServerConfig)

          ServerConfigError.raise!(
            "server config must be a ServerConfig or Hash",
            code: "agent_core.mcp.server_config.server_config_must_be_a_server_config_or_hash",
            details: { value_class: value.class.name },
          ) unless value.is_a?(Hash)

          value.each_key do |key|
            next if key.is_a?(Symbol)

            ServerConfigError.raise!(
              "mcp server config keys must be Symbols (got #{key.class})",
              code: "agent_core.mcp.server_config.keys_must_be_symbols_got",
              details: { key_class: key.class.name, key_preview: value_preview(key) },
            )
          end

          new(
            id: value.fetch(:id, nil),
            transport: value.fetch(:transport, nil),
            command: value.fetch(:command, nil),
            args: value.fetch(:args, nil),
            env: value.fetch(:env, nil),
            env_provider: value.fetch(:env_provider, nil),
            chdir: value.fetch(:chdir, nil),
            url: value.fetch(:url, nil),
            headers: value.fetch(:headers, nil),
            headers_provider: value.fetch(:headers_provider, nil),
            on_stdout_line: value.fetch(:on_stdout_line, nil),
            on_stderr_line: value.fetch(:on_stderr_line, nil),
            protocol_version: value.fetch(:protocol_version, nil),
            client_info: value.fetch(:client_info, nil),
            capabilities: value.fetch(:capabilities, nil),
            timeout_s: value.fetch(:timeout_s, nil),
            open_timeout_s: value.fetch(:open_timeout_s, nil),
            read_timeout_s: value.fetch(:read_timeout_s, nil),
            sse_max_reconnects: value.fetch(:sse_max_reconnects, nil),
            max_response_bytes: value.fetch(:max_response_bytes, nil),
          )
        end

        private

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end

        def normalize_env(value)
          ServerConfigError.raise!(
            "env must be a Hash",
            code: "agent_core.mcp.server_config.env_must_be_a_hash",
            details: { value_class: value.class.name },
          ) if !value.nil? && !value.is_a?(Hash)

          hash = value || {}
          hash.each_with_object({}) do |(k, v), out|
            key = k.to_s
            next if key.strip.empty?

            out[key] = v.nil? ? nil : v.to_s
          end
        end

        def normalize_headers(value)
          return nil if value.nil?
          ServerConfigError.raise!(
            "headers must be a Hash",
            code: "agent_core.mcp.server_config.headers_must_be_a_hash",
            details: { value_class: value.class.name },
          ) unless value.is_a?(Hash)

          value.each_with_object({}) do |(k, v), out|
            key = k.to_s
            next if key.strip.empty?
            next if v.nil?

            out[key] = v.to_s
          end
        end

        def normalize_transport(value)
          raw = value.to_s.strip
          return :stdio if raw.empty?

          case raw
          when "stdio"
            :stdio
          when "streamable_http", "streamable-http"
            :streamable_http
          else
            ServerConfigError.raise!(
              "transport must be :stdio or :streamable_http",
              code: "agent_core.mcp.server_config.transport_must_be_stdio_or_streamable_http",
              details: { transport: value.to_s },
            )
          end
        end

        def normalize_protocol_version(value)
          s = value.to_s.strip
          s.empty? ? AgentCore::MCP::DEFAULT_PROTOCOL_VERSION : s
        end

        def normalize_timeout_s(value)
          raw = blank?(value) ? AgentCore::MCP::DEFAULT_TIMEOUT_S : value
          timeout_s = Float(raw, exception: false)
          ServerConfigError.raise!(
            "timeout_s must be a number",
            code: "agent_core.mcp.server_config.timeout_s_must_be_a_number",
            details: { value_class: raw.class.name, value_preview: self.class.value_preview(raw) },
          ) if timeout_s.nil?
          ServerConfigError.raise!(
            "timeout_s must be a finite number",
            code: "agent_core.mcp.server_config.timeout_s_must_be_finite",
            details: { value_class: raw.class.name, value_preview: self.class.value_preview(raw) },
          ) unless timeout_s.finite?
          ServerConfigError.raise!(
            "timeout_s must be positive",
            code: "agent_core.mcp.server_config.timeout_s_must_be_positive",
            details: { timeout_s: timeout_s },
          ) if timeout_s <= 0

          timeout_s
        end

        def normalize_optional_timeout_s(value, field:)
          return nil if blank?(value)

          timeout_s = Float(value, exception: false)
          ServerConfigError.raise!(
            "#{field} must be a number",
            code: "agent_core.mcp.server_config.field_must_be_a_number",
            details: { field: field.to_s, value_class: value.class.name, value_preview: self.class.value_preview(value) },
          ) if timeout_s.nil?
          ServerConfigError.raise!(
            "#{field} must be a finite number",
            code: "agent_core.mcp.server_config.field_must_be_finite",
            details: { field: field.to_s, value_class: value.class.name, value_preview: self.class.value_preview(value) },
          ) unless timeout_s.finite?
          ServerConfigError.raise!(
            "#{field} must be positive",
            code: "agent_core.mcp.server_config.field_must_be_positive",
            details: { field: field.to_s, value: timeout_s },
          ) if timeout_s <= 0

          timeout_s
        end

        def normalize_optional_positive_integer(value, field:)
          return nil if blank?(value)

          i = strict_integer(value)
          ServerConfigError.raise!(
            "#{field} must be an Integer",
            code: "agent_core.mcp.server_config.field_must_be_an_integer",
            details: { field: field.to_s, value_class: value.class.name, value_preview: self.class.value_preview(value) },
          ) if i.nil?
          ServerConfigError.raise!(
            "#{field} must be positive",
            code: "agent_core.mcp.server_config.field_must_be_positive",
            details: { field: field.to_s, value: i },
          ) if i <= 0

          i
        end

        def normalize_optional_callable(value, field:)
          return nil if value.nil?
          return value if value.respond_to?(:call)

          ServerConfigError.raise!(
            "#{field} must respond to #call",
            code: "agent_core.mcp.server_config.field_must_respond_to_call",
            details: { field: field.to_s, value_class: value.class.name },
          )
        end

        def self.value_preview(value, max_bytes: 200)
          s = value.to_s
          s.bytesize > max_bytes ? s.byteslice(0, max_bytes).to_s : s
        end

        def strict_integer(value)
          case value
          when Integer
            value
          when String
            s = value.strip
            return nil if s.empty?
            return nil unless s.match?(/\A[+-]?\d+\z/)

            Integer(s, 10)
          else
            nil
          end
        end
      end
  end
end
