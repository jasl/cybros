module AgentCore
  # Base module for content blocks.
  module ContentBlock
    def self.from_h(hash)
      return TextContent.new(text: hash.to_s) unless hash.is_a?(Hash)

      type = hash.fetch("type", nil).to_s.strip.downcase.tr("-", "_").to_sym

      case type
      when :text
        TextContent.new(text: hash.fetch("text", nil))
      when :image
        ImageContent.from_h(hash)
      when :document
        DocumentContent.from_h(hash)
      when :audio
        AudioContent.from_h(hash)
      when :tool_use
        ToolUseContent.new(
          id: hash.fetch("id", nil),
          name: hash.fetch("name", nil),
          input: hash.fetch("input", nil),
        )
      when :tool_result
        ToolResultContent.new(
          tool_use_id: hash.fetch("tool_use_id", nil),
          content: hash.fetch("content", nil),
          error: hash.fetch("error", false),
        )
      else
        TextContent.new(text: hash.fetch("text", nil) || hash.to_s)
      end
    rescue StandardError
      TextContent.new(text: hash.to_s)
    end
  end
end
