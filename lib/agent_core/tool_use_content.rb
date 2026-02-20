# frozen_string_literal: true

module AgentCore
  # Tool use content block (in assistant messages).
  class ToolUseContent
    attr_reader :id, :name, :input

    def initialize(id:, name:, input:)
      @id = id
      @name = name
      @input = (input || {}).freeze
    end

    def type = :tool_use

    def to_h
      { type: :tool_use, id: id, name: name, input: input }
    end

    def ==(other)
      other.is_a?(ToolUseContent) && id == other.id && name == other.name && input == other.input
    end
  end
end
