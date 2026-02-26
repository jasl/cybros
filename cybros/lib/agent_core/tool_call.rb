module AgentCore
  # A tool call requested by the assistant.
  class ToolCall
    MAX_ARGUMENTS_RAW_BYTES = 4_000

    attr_reader :id, :name, :arguments, :arguments_parse_error, :arguments_raw

    def initialize(id:, name:, arguments:, arguments_parse_error: nil, arguments_raw: nil)
      @id = id
      @name = name
      @arguments = Utils.deep_stringify_keys(arguments || {}).freeze
      @arguments_parse_error = arguments_parse_error
      @arguments_raw = coerce_arguments_raw(arguments_raw)
    end

    def arguments_valid?
      arguments_parse_error.nil?
    end

    def to_h
      h = { id: id, name: name, arguments: arguments }
      h[:arguments_parse_error] = arguments_parse_error if arguments_parse_error
      if arguments_parse_error && arguments_raw
        h[:arguments_raw] = arguments_raw
      end
      h
    end

    def ==(other)
      other.is_a?(ToolCall) &&
        id == other.id &&
        name == other.name &&
        arguments == other.arguments &&
        arguments_parse_error == other.arguments_parse_error &&
        arguments_raw == other.arguments_raw
    end

    def self.from_h(hash)
      ValidationError.raise!(
        "tool_call must be a Hash (got #{hash.class})",
        code: "agent_core.tool_call.tool_call_must_be_a_hash_got",
        details: { value_class: hash.class.name },
      ) unless hash.is_a?(Hash)

      new(
        id: hash.fetch("id", hash.fetch(:id, nil)),
        name: hash.fetch("name", hash.fetch(:name, nil)),
        arguments: hash.fetch("arguments", hash.fetch(:arguments, {})) || {},
        arguments_parse_error: hash.fetch("arguments_parse_error", hash.fetch(:arguments_parse_error, nil)),
        arguments_raw: hash.fetch("arguments_raw", hash.fetch(:arguments_raw, nil)),
      )
    end

    private

    def coerce_arguments_raw(value)
      raw = value.to_s
      raw = Utils.truncate_utf8_bytes(raw, max_bytes: MAX_ARGUMENTS_RAW_BYTES)
      raw.strip.empty? ? nil : raw
    rescue StandardError
      nil
    end
  end
end
