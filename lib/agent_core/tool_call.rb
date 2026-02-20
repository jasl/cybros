# frozen_string_literal: true

module AgentCore
  # A tool call requested by the assistant.
  class ToolCall
    attr_reader :id, :name, :arguments, :arguments_parse_error

    def initialize(id:, name:, arguments:, arguments_parse_error: nil)
      @id = id
      @name = name
      @arguments = Utils.deep_stringify_keys(arguments || {}).freeze
      @arguments_parse_error = arguments_parse_error
    end

    def arguments_valid?
      arguments_parse_error.nil?
    end

    def to_h
      h = { id: id, name: name, arguments: arguments }
      h[:arguments_parse_error] = arguments_parse_error if arguments_parse_error
      h
    end

    def ==(other)
      other.is_a?(ToolCall) &&
        id == other.id &&
        name == other.name &&
        arguments == other.arguments &&
        arguments_parse_error == other.arguments_parse_error
    end

    def self.from_h(hash)
      h = hash.transform_keys(&:to_sym)
      new(
        id: h[:id],
        name: h[:name],
        arguments: h[:arguments] || {},
        arguments_parse_error: h[:arguments_parse_error]
      )
    end
  end
end
