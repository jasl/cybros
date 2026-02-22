# frozen_string_literal: true

module AgentCore
  module ContextManagement
    class ToolOutputPruner
      DEFAULT_RECENT_TURNS = 2
      DEFAULT_MAX_OUTPUT_CHARS = 500
      DEFAULT_PREVIEW_CHARS = 200

      attr_reader :recent_turns, :max_output_chars, :preview_chars

      def initialize(recent_turns: DEFAULT_RECENT_TURNS, max_output_chars: DEFAULT_MAX_OUTPUT_CHARS, preview_chars: DEFAULT_PREVIEW_CHARS)
        @recent_turns = Integer(recent_turns)
        @max_output_chars = Integer(max_output_chars)
        @preview_chars = Integer(preview_chars)

        raise ValidationError, "recent_turns must be >= 0" if @recent_turns.negative?
        raise ValidationError, "max_output_chars must be > 0" if @max_output_chars <= 0
        raise ValidationError, "preview_chars must be > 0" if @preview_chars <= 0
      end

      # Prune older tool outputs in the prompt view to reduce token/char usage.
      #
      # The last `recent_turns` user messages (and everything after them) are protected.
      #
      # @param messages [Array<AgentCore::Message>]
      # @return [Array<(Array<AgentCore::Message>, Hash)>] pruned_messages, stats
      def call(messages:)
        messages = Array(messages)
        boundary = boundary_index(messages)

        trimmed_count = 0
        chars_saved = 0

        pruned =
          messages.each_with_index.map do |msg, idx|
            next msg if idx >= boundary

            maybe_prune_message(msg) do |saved|
              trimmed_count += 1
              chars_saved += saved
            end
          end

        [pruned, { trimmed_count: trimmed_count, chars_saved: chars_saved }]
      rescue StandardError
        [Array(messages), { trimmed_count: 0, chars_saved: 0 }]
      end

      private

        def boundary_index(messages)
          return 0 if messages.empty?
          return messages.length if recent_turns == 0

          seen = 0
          (messages.length - 1).downto(0) do |idx|
            msg = messages[idx]
            next unless msg.respond_to?(:user?) && msg.user?

            seen += 1
            return idx if seen == recent_turns
          end

          0
        rescue StandardError
          0
        end

        def maybe_prune_message(msg)
          return msg unless prune_candidate?(msg)

          text = msg.respond_to?(:text) ? msg.text.to_s : msg.to_s
          return msg if text.length <= max_output_chars

          preview = text[0, preview_chars].to_s

          replacement =
            "[Trimmed tool output — #{text.length} chars → #{preview.length} char preview]\n" \
              "#{preview}..."

          return msg if replacement.length >= text.length

          saved = text.length - replacement.length
          saved = 0 if saved.negative?

          yield saved if block_given?

          Message.new(
            role: msg.role,
            content: replacement,
            tool_calls: msg.tool_calls,
            tool_call_id: msg.tool_call_id,
            name: msg.name,
            metadata: msg.metadata,
          )
        rescue StandardError
          msg
        end

        def prune_candidate?(msg)
          return true if msg.respond_to?(:tool_result?) && msg.tool_result?

          return false unless msg.respond_to?(:system?) && msg.system?

          text = msg.respond_to?(:text) ? msg.text.to_s : ""
          text.start_with?("[tool:")
        rescue StandardError
          false
        end
    end
  end
end
