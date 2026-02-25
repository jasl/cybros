# frozen_string_literal: true

module AgentCore
  module Resources
    module Provider
      # Represents an LLM response.
      #
      # Providers normalize their API responses into this format.
      # DAG executors use this to determine next steps (tool calls, final text, etc.).
      class Response
        attr_reader :message, :usage, :raw, :stop_reason

        # @param message [Message] The assistant message
        # @param usage [Usage, nil] Token usage information
        # @param raw [Hash, nil] Raw provider-specific response
        # @param stop_reason [Symbol] Why the response ended
        #   (:end_turn, :tool_use, :max_tokens, :stop_sequence)
        def initialize(message:, usage: nil, raw: nil, stop_reason: :end_turn)
          @message = message
          @usage = usage
          @raw = raw
          @stop_reason = stop_reason
        end

        # Whether this response contains tool calls that need execution.
        def has_tool_calls?
          message&.has_tool_calls?
        end

        # Convenience: get tool calls from the message.
        def tool_calls
          message&.tool_calls || []
        end

        # Whether the response ended because of tool use.
        def tool_use?
          stop_reason == :tool_use
        end

        # Whether the response reached max tokens.
        def truncated?
          stop_reason == :max_tokens
        end
      end
    end
  end
end
