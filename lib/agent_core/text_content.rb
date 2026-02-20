# frozen_string_literal: true

module AgentCore
  # Text content block.
  class TextContent
    attr_reader :text

    def initialize(text:)
      @text = text
    end

    def type = :text

    def to_h
      { type: :text, text: text }
    end

    def ==(other)
      other.is_a?(TextContent) && text == other.text
    end
  end
end
