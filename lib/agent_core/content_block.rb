# frozen_string_literal: true

module AgentCore
  # Base module for content blocks.
  module ContentBlock
    def self.from_h(hash)
      h = hash.transform_keys(&:to_sym)
      case h[:type]&.to_sym
      when :text then TextContent.new(text: h[:text])
      when :image then ImageContent.from_h(h)
      when :document then DocumentContent.from_h(h)
      when :audio then AudioContent.from_h(h)
      when :tool_use then ToolUseContent.new(id: h[:id], name: h[:name], input: h[:input])
      when :tool_result then ToolResultContent.new(tool_use_id: h[:tool_use_id], content: h[:content], error: h[:error])
      else
        TextContent.new(text: h[:text] || h.to_s)
      end
    end
  end
end
