require "timeout"

module AgentCore
  module Resources
    module Tools
      # The result of executing a tool.
      #
      # Contains content blocks (text, images, etc.) and error status.
      # Normalized across all tool sources (native, MCP, skills).
      class ToolResult
        DEFAULT_PROJECTION_PREVIEW_BYTES = 512
        DEFAULT_PROJECTED_TEXT_BYTES = 4_096
        TRUNCATED_NOTICE = "[tool output truncated]"
        NON_TEXT_NOTICE = "[non-text tool output omitted]"
        REDACTION_PATTERNS = [
          [/(api[_-]?key\s*[=:]\s*)([^\s]+)/i, "\\1[redacted]"],
          [/(token\s*[=:]\s*)([^\s]+)/i, "\\1[redacted]"],
          [/(bearer\s+)([^\s]+)/i, "\\1[redacted]"],
        ].freeze
        TOOL_EXECUTION_FAILURE_CLASSES = %w[validation_error implementation_error remote_api_error timeout rate_limit auth unknown].freeze

        attr_reader :content, :error, :metadata

        # @param content [Array<Hash>] Content blocks
        #   Each block: { type: :text, text: "..." } or { type: :image, ... }
        # @param error [Boolean] Whether this result represents an error
        # @param metadata [Hash] Optional metadata (timing, byte counts, etc.)
        def initialize(content:, error: false, metadata: {})
          normalized = Array(content).map do |block|
            normalize_block(block)
          end

          @content = normalized.map(&:freeze).freeze
          @error = !!error
          meta = metadata || {}
          ValidationError.raise!(
            "tool result metadata must be a Hash",
            code: "agent_core.tools.tool_result.tool_result_metadata_must_be_a_hash",
            details: { metadata_class: meta.class.name },
          ) unless meta.is_a?(Hash)
          @metadata = AgentCore::Utils.deep_stringify_keys(meta).freeze
        end

        def error? = error

        # Convenience: get text content as a single string.
        def text
          content.filter_map { |block|
            block[:text] if block[:type] == :text
          }.join("\n")
        end

        # Whether this result contains non-text content blocks (images, documents, etc.).
        def has_non_text_content?
          content.any? { |block|
            block[:type] && block[:type] != :text
          }
        end

        # Convert content hash blocks to ContentBlock objects.
        #
        # Used by the Runner to build Messages with proper content blocks
        # when tool results include images or other media.
        #
        # @return [Array<ContentBlock>] Array of typed content block objects
        def to_content_blocks
          content.map { |block| AgentCore::ContentBlock.from_h(block) }
        end

        def to_h
          { content: content, error: error, metadata: metadata }
        end

        def artifact_refs
          refs = metadata["artifact_refs"]
          refs.is_a?(Array) ? AgentCore::Utils.deep_stringify_keys(refs) : []
        rescue StandardError
          []
        end

        def projection_meta
          {
            "error" => error?,
            "content_block_count" => content.length,
            "has_non_text_content" => has_non_text_content?,
            "text_bytes" => text.to_s.bytesize,
            "line_count" => text.to_s.lines.count,
            "metadata" => metadata.except("artifact_refs"),
          }
        end

        def projection_preview(max_text_bytes: DEFAULT_PROJECTION_PREVIEW_BYTES)
          sanitized = self.class.sanitize_text_for_projection(text, max_bytes: max_text_bytes)

          {
            "text" => projection_text_with_non_text_notice(sanitized.fetch(:text)),
            "error" => error?,
            "truncated" => sanitized.fetch(:truncated),
            "redacted" => sanitized.fetch(:redacted),
            "non_text_content" => has_non_text_content?,
          }
        end

        def projected_copy(max_text_bytes: DEFAULT_PROJECTED_TEXT_BYTES)
          sanitized = self.class.sanitize_text_for_projection(text, max_bytes: max_text_bytes)

          ToolResult.new(
            content: projected_content(sanitized.fetch(:text)),
            error: error?,
            metadata: metadata.merge(
              "projection" => {
                "truncated" => sanitized.fetch(:truncated),
                "redacted" => sanitized.fetch(:redacted),
                "non_text_content" => has_non_text_content?,
              },
            ),
          )
        end

        # Build a ToolResult from a Hash (symbol or string keys) or JSON String.
        #
        # Intended for app-side persistence round-trips and job queues.
        #
        # @param value [Hash, String]
        # @return [ToolResult]
        def self.from_h(value)
          h =
            case value
            when self
              return value
            when String
              begin
                require "json"
                JSON.parse(value)
              rescue JSON::ParserError => e
                ValidationError.raise!(
                  "tool result is not valid JSON: #{e.message}",
                  code: "agent_core.tools.tool_result.tool_result_is_not_valid_json",
                )
              end
            when Hash
              value
            else
              ValidationError.raise!(
                "tool result must be a Hash or JSON String (got #{value.class})",
                code: "agent_core.tools.tool_result.tool_result_must_be_a_hash_or_json_string_got",
                details: { value_class: value.class.name },
              )
            end

          ValidationError.raise!(
            "tool result must be a Hash",
            code: "agent_core.tools.tool_result.tool_result_must_be_a_hash",
            details: { value_class: h.class.name },
          ) unless h.is_a?(Hash)

          content = h.fetch("content", h.fetch(:content, nil))
          ValidationError.raise!(
            "tool result content must be an Array",
            code: "agent_core.tools.tool_result.tool_result_content_must_be_an_array",
            details: { content_class: content.class.name },
          ) unless content.is_a?(Array)

          error = h.fetch("error", h.fetch(:error, false))

          metadata = h.fetch("metadata", h.fetch(:metadata, {}))
          metadata = {} if metadata.nil?
          ValidationError.raise!(
            "tool result metadata must be a Hash",
            code: "agent_core.tools.tool_result.tool_result_metadata_must_be_a_hash",
            details: { metadata_class: metadata.class.name },
          ) unless metadata.is_a?(Hash)

          new(
            content: content,
            error: !!error,
            metadata: metadata,
          )
        end

        def self.coerce(value, error: false, metadata: {})
          case value
          when self
            value
          when Hash, String
            from_h(value)
          else
            new(
              content: [{ type: :text, text: value.to_s }],
              error: error,
              metadata: metadata,
            )
          end
        end

        # Build a successful text result.
        def self.success(text:, metadata: {})
          new(
            content: [{ type: :text, text: text }],
            error: false,
            metadata: metadata
          )
        end

        # Build an error result.
        def self.error(text:, metadata: {})
          new(
            content: [{ type: :text, text: text }],
            error: true,
            metadata: metadata
          )
        end

        def self.error_with_tool_execution(text:, error:, source:, metadata: {})
          failure = tool_execution_failure_for(error, source: source)
          error(text: text, metadata: with_tool_execution_metadata(metadata, **failure))
        end

        def self.with_tool_execution_metadata(metadata, failure_class:, failure_code: nil, retryable: nil)
          base = metadata.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(metadata) : {}
          tool_execution = base["tool_execution"].is_a?(Hash) ? base["tool_execution"].deep_dup : {}

          tool_execution["failure_class"] = failure_class.to_s
          tool_execution["failure_code"] = failure_code.to_s if failure_code.to_s.present?
          tool_execution["retryable"] = retryable unless retryable.nil?

          base.merge("tool_execution" => tool_execution)
        end

        def self.tool_execution_failure_for(error, source:)
          recognized = recognizable_failure(error, source: source)

          if error.is_a?(AgentCore::ValidationError)
            return {
              failure_class: "validation_error",
              failure_code: error.code.to_s.presence,
              retryable: false,
            }
          end

          return recognized if recognized

          {
            failure_class: source.to_s == "mcp" ? "remote_api_error" : "implementation_error",
            failure_code: default_failure_code_for(error, source: source),
            retryable: source.to_s == "mcp",
          }
        end

        # Build a result with multiple content blocks.
        def self.with_content(blocks, error: false, metadata: {})
          new(content: blocks, error: error, metadata: metadata)
        end

        private

        def normalize_block(block)
          unless block.is_a?(Hash)
            return { type: :text, text: block.to_s }
          end

          h = AgentCore::Utils.symbolize_keys(block)
          h = normalize_type!(h)
          h = normalize_source_type!(h)

          if h[:type].nil?
            return h.key?(:text) ? h.merge(type: :text) : { type: :text, text: block.to_s }
          end

          h
        end

        def normalize_type!(hash)
          type = hash[:type]
          return hash if type.nil?

          sym = type.is_a?(Symbol) ? type : type.to_s.to_sym
          sym == type ? hash : hash.merge(type: sym)
        end

        def normalize_source_type!(hash)
          st = hash[:source_type]
          return hash if st.nil?

          sym = st.is_a?(Symbol) ? st : st.to_s.to_sym
          sym == st ? hash : hash.merge(source_type: sym)
        end

        def projected_content(text)
          blocks = []
          text = text.to_s
          blocks << { type: :text, text: text } unless text.empty?
          blocks << { type: :text, text: NON_TEXT_NOTICE } if has_non_text_content?
          blocks << { type: :text, text: error? ? "[tool result omitted]" : "[tool output omitted]" } if blocks.empty?
          blocks
        end

        def projection_text_with_non_text_notice(text)
          base = text.to_s
          return NON_TEXT_NOTICE if base.empty? && has_non_text_content?
          return base unless has_non_text_content?
          return "#{base}\n\n#{NON_TEXT_NOTICE}" unless base.empty?

          NON_TEXT_NOTICE
        end

        class << self
          private

            def recognizable_failure(error, source:)
              if timeout_error?(error)
                return {
                  failure_class: "timeout",
                  failure_code: timeout_failure_code_for(error, source: source),
                  retryable: true,
                }
              end

              if rate_limit_error?(error)
                return {
                  failure_class: "rate_limit",
                  failure_code: default_failure_code_for(error, source: source),
                  retryable: true,
                }
              end

              if auth_error?(error)
                {
                  failure_class: "auth",
                  failure_code: default_failure_code_for(error, source: source),
                  retryable: false,
                }
              end
            end

            def timeout_error?(error)
              error.is_a?(::Timeout::Error) ||
                error.is_a?(AgentCore::MCP::TimeoutError) ||
                error.class.name.to_s.downcase.include?("timeout")
            end

            def rate_limit_error?(error)
              status_code(error) == 429 || error.message.to_s.downcase.include?("rate limit")
            end

            def auth_error?(error)
              status = status_code(error)
              return true if [401, 403].include?(status)

              message = error.message.to_s.downcase
              message.include?("unauthorized") || message.include?("forbidden") || message.include?("authentication")
            end

            def timeout_failure_code_for(error, source:)
              return "mcp_timeout" if error.is_a?(AgentCore::MCP::TimeoutError)
              return "timeout" unless source.to_s == "mcp"

              default_failure_code_for(error, source: source) || "mcp_timeout"
            end

            def default_failure_code_for(error, source:)
              return error.code.to_s if error.respond_to?(:code) && error.code.to_s.present?

              status = status_code(error)
              return "http_#{status}" if status

              return "mcp_transport_error" if error.is_a?(AgentCore::MCP::TransportError)
              return "mcp_closed" if error.is_a?(AgentCore::MCP::ClosedError)
              return "mcp_protocol_error" if error.is_a?(AgentCore::MCP::ProtocolError)
              return "mcp_server_error" if error.is_a?(AgentCore::MCP::ServerError)
              return "mcp_json_rpc_error" if error.is_a?(AgentCore::MCP::JsonRPCError)
              return "mcp_remote_api_error" if source.to_s == "mcp"

              nil
            end

            def status_code(error)
              raw = error.respond_to?(:status) ? error.status : nil
              Integer(raw, exception: false)
            rescue StandardError
              nil
            end

          public

          def sanitize_text_for_projection(text, max_bytes:)
            sanitized = text.to_s
            redacted = false

            REDACTION_PATTERNS.each do |pattern, replacement|
              updated = sanitized.gsub(pattern, replacement)
              redacted ||= updated != sanitized
              sanitized = updated
            end

            truncated = sanitized.bytesize > max_bytes
            body_max_bytes = truncated ? [max_bytes - ("\n\n#{TRUNCATED_NOTICE}").bytesize, 0].max : max_bytes
            body = AgentCore::Utils.truncate_utf8_bytes(sanitized, max_bytes: body_max_bytes)
            body = "#{body}\n\n#{TRUNCATED_NOTICE}" if truncated

            {
              text: body,
              redacted: redacted,
              truncated: truncated,
            }
          end
        end
      end
    end
  end
end
