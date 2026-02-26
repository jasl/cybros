module AgentCore
  # Tool result content block.
  class ToolResultContent
    attr_reader :tool_use_id, :content, :error

    def initialize(tool_use_id:, content:, error: false)
      @tool_use_id = tool_use_id
      @content = content
      @error = !!error
    end

    def type = :tool_result
    def error? = error

    def to_h
      { type: :tool_result, tool_use_id: tool_use_id, content: content, error: error }
    end

    def ==(other)
      other.is_a?(ToolResultContent) &&
        tool_use_id == other.tool_use_id &&
        content == other.content &&
        error == other.error
    end
  end
end
