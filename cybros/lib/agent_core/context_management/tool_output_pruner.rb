module AgentCore
  module ContextManagement
    class ToolOutputPruner
      DEFAULT_RECENT_TURNS = 2
      DEFAULT_KEEP_LAST_ASSISTANT_MESSAGES = 3

      DEFAULT_SOFT_TRIM_MAX_CHARS = 4_000
      DEFAULT_SOFT_TRIM_HEAD_CHARS = 1_500
      DEFAULT_SOFT_TRIM_TAIL_CHARS = 1_500

      DEFAULT_HARD_CLEAR_ENABLED = true
      DEFAULT_HARD_CLEAR_PLACEHOLDER = "[Old tool result content cleared]"
      DEFAULT_HARD_CLEAR_MIN_TOTAL_CHARS = 50_000

      attr_reader(
        :recent_turns,
        :keep_last_assistant_messages,
        :soft_trim_max_chars,
        :soft_trim_head_chars,
        :soft_trim_tail_chars,
        :hard_clear_enabled,
        :hard_clear_placeholder,
        :hard_clear_min_total_chars,
      )

      def initialize(
        recent_turns: DEFAULT_RECENT_TURNS,
        keep_last_assistant_messages: DEFAULT_KEEP_LAST_ASSISTANT_MESSAGES,
        tools_allow: [],
        tools_deny: [],
        soft_trim_max_chars: DEFAULT_SOFT_TRIM_MAX_CHARS,
        soft_trim_head_chars: DEFAULT_SOFT_TRIM_HEAD_CHARS,
        soft_trim_tail_chars: DEFAULT_SOFT_TRIM_TAIL_CHARS,
        hard_clear_enabled: DEFAULT_HARD_CLEAR_ENABLED,
        hard_clear_placeholder: DEFAULT_HARD_CLEAR_PLACEHOLDER,
        hard_clear_min_total_chars: DEFAULT_HARD_CLEAR_MIN_TOTAL_CHARS
      )
        @recent_turns =
          Integer(recent_turns, exception: false).tap do |value|
            ValidationError.raise!(
              "recent_turns must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.recent_turns_must_be_an_integer",
              details: { recent_turns: recent_turns },
            ) if value.nil?
          end

        ValidationError.raise!(
          "recent_turns must be >= 0",
          code: "agent_core.context_management.tool_output_pruner.recent_turns_must_be_gte_0",
          details: { recent_turns: @recent_turns },
        ) if @recent_turns.negative?

        @keep_last_assistant_messages =
          Integer(keep_last_assistant_messages, exception: false).tap do |value|
            ValidationError.raise!(
              "keep_last_assistant_messages must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.keep_last_assistant_messages_must_be_an_integer",
              details: { keep_last_assistant_messages: keep_last_assistant_messages },
            ) if value.nil?
          end

        ValidationError.raise!(
          "keep_last_assistant_messages must be >= 0",
          code: "agent_core.context_management.tool_output_pruner.keep_last_assistant_messages_must_be_gte_0",
          details: { keep_last_assistant_messages: @keep_last_assistant_messages },
        ) if @keep_last_assistant_messages.negative?

        @soft_trim_max_chars =
          Integer(soft_trim_max_chars, exception: false).tap do |value|
            ValidationError.raise!(
              "soft_trim_max_chars must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.soft_trim_max_chars_must_be_an_integer",
              details: { soft_trim_max_chars: soft_trim_max_chars },
            ) if value.nil?
          end
        ValidationError.raise!(
          "soft_trim_max_chars must be > 0",
          code: "agent_core.context_management.tool_output_pruner.soft_trim_max_chars_must_be_gt_0",
          details: { soft_trim_max_chars: @soft_trim_max_chars },
        ) if @soft_trim_max_chars <= 0

        @soft_trim_head_chars =
          Integer(soft_trim_head_chars, exception: false).tap do |value|
            ValidationError.raise!(
              "soft_trim_head_chars must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.soft_trim_head_chars_must_be_an_integer",
              details: { soft_trim_head_chars: soft_trim_head_chars },
            ) if value.nil?
          end

        ValidationError.raise!(
          "soft_trim_head_chars must be >= 0",
          code: "agent_core.context_management.tool_output_pruner.soft_trim_head_chars_must_be_gte_0",
          details: { soft_trim_head_chars: @soft_trim_head_chars },
        ) if @soft_trim_head_chars.negative?

        @soft_trim_tail_chars =
          Integer(soft_trim_tail_chars, exception: false).tap do |value|
            ValidationError.raise!(
              "soft_trim_tail_chars must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.soft_trim_tail_chars_must_be_an_integer",
              details: { soft_trim_tail_chars: soft_trim_tail_chars },
            ) if value.nil?
          end

        ValidationError.raise!(
          "soft_trim_tail_chars must be >= 0",
          code: "agent_core.context_management.tool_output_pruner.soft_trim_tail_chars_must_be_gte_0",
          details: { soft_trim_tail_chars: @soft_trim_tail_chars },
        ) if @soft_trim_tail_chars.negative?

        @hard_clear_enabled = hard_clear_enabled == true

        @hard_clear_placeholder = hard_clear_placeholder.to_s.strip
        ValidationError.raise!(
          "hard_clear_placeholder must be non-empty",
          code: "agent_core.context_management.tool_output_pruner.hard_clear_placeholder_must_be_non_empty",
        ) if @hard_clear_placeholder.empty?

        @hard_clear_min_total_chars =
          Integer(hard_clear_min_total_chars, exception: false).tap do |value|
            ValidationError.raise!(
              "hard_clear_min_total_chars must be an Integer",
              code: "agent_core.context_management.tool_output_pruner.hard_clear_min_total_chars_must_be_an_integer",
              details: { hard_clear_min_total_chars: hard_clear_min_total_chars },
            ) if value.nil?
          end

        ValidationError.raise!(
          "hard_clear_min_total_chars must be >= 0",
          code: "agent_core.context_management.tool_output_pruner.hard_clear_min_total_chars_must_be_gte_0",
          details: { hard_clear_min_total_chars: @hard_clear_min_total_chars },
        ) if @hard_clear_min_total_chars.negative?

        @tools_allow_raw = normalize_patterns(tools_allow).freeze
        @tools_deny_raw = normalize_patterns(tools_deny).freeze

        @tools_allow_compiled = compile_patterns(@tools_allow_raw).freeze
        @tools_deny_compiled = compile_patterns(@tools_deny_raw).freeze
      end

      # Prune older tool outputs in the prompt view to reduce token/char usage.
      #
      # The last `recent_turns` user messages (and everything after them) are protected.
      #
      # @param messages [Array<AgentCore::Message>]
      # @return [Array<(Array<AgentCore::Message>, Hash)>] pruned_messages, stats
      def call(messages:)
        messages = Array(messages)
        prune_start = prune_start_index(messages)
        return [messages, { trimmed_count: 0, chars_saved: 0 }] if prune_start >= messages.length

        boundary = boundary_index(messages)

        trimmed_count = 0
        chars_saved = 0

        pruned =
          messages.each_with_index.map do |msg, idx|
            next msg if idx < prune_start || idx >= boundary

            maybe_soft_trim_message(msg) do |saved|
              trimmed_count += 1
              chars_saved += saved
            end
          end

        [pruned, { trimmed_count: trimmed_count, chars_saved: chars_saved }]
      rescue StandardError
        [Array(messages), { trimmed_count: 0, chars_saved: 0 }]
      end

      def hard_clear_candidate_indexes(messages:)
        messages = Array(messages)
        prune_start = prune_start_index(messages)
        return [] if prune_start >= messages.length

        boundary = boundary_index(messages)

        out = []
        messages.each_with_index do |msg, idx|
          next if idx < prune_start || idx >= boundary
          next unless prune_candidate?(msg)

          tool_name = tool_name_for_matching(msg)
          next unless tool_prunable?(tool_name)

          out << idx
        end
        out
      rescue StandardError
        []
      end

      def hard_clear_message(msg)
        text = msg.respond_to?(:text) ? msg.text.to_s : msg.to_s
        header, = tool_header_and_body(text)

        replacement =
          if header
            "#{header}\n#{hard_clear_placeholder}"
          else
            hard_clear_placeholder
          end

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

      def prunable_body_chars(msg)
        text = msg.respond_to?(:text) ? msg.text.to_s : msg.to_s
        _header, _name, body = tool_header_and_body(text)
        body.length
      rescue StandardError
        0
      end

      def tools_allow_count = @tools_allow_raw.length
      def tools_deny_count = @tools_deny_raw.length

      private

        def normalize_patterns(value)
          list =
            case value
            when String
              [value]
            when Array
              value
            else
              []
            end

          Array(list)
            .filter_map { |v| v.is_a?(String) ? v.strip : nil }
            .reject(&:empty?)
        rescue StandardError
          []
        end

        Pattern = Data.define(:kind, :value)

        def compile_patterns(patterns)
          Array(patterns).filter_map do |raw|
            normalized = normalize_glob(raw)
            next if normalized.empty?

            if normalized == "*"
              Pattern.new(kind: :all, value: nil)
            elsif !normalized.include?("*")
              Pattern.new(kind: :exact, value: normalized)
            else
              escaped = Regexp.escape(normalized).gsub("\\*", ".*")
              Pattern.new(kind: :regex, value: Regexp.new("\\A#{escaped}\\z"))
            end
          end
        rescue StandardError
          []
        end

        def normalize_glob(value)
          value.to_s.strip.downcase
        rescue StandardError
          ""
        end

        def matches_any_pattern?(compiled, value)
          compiled = Array(compiled)
          return false if compiled.empty?
          return true if compiled.any? { |pat| pat.kind == :all }

          val = normalize_glob(value)
          return false if val.empty?

          compiled.any? do |pat|
            case pat.kind
            when :all
              true
            when :exact
              val == pat.value
            when :regex
              pat.value.match?(val)
            else
              false
            end
          end
        rescue StandardError
          false
        end

        def tool_prunable?(tool_name)
          name = tool_name.to_s
          return false if matches_any_pattern?(@tools_deny_compiled, name)

          return true if @tools_allow_compiled.empty?

          matches_any_pattern?(@tools_allow_compiled, name)
        rescue StandardError
          false
        end

        def tool_name_for_matching(msg)
          name = msg.respond_to?(:name) ? msg.name.to_s : ""
          name = name.strip
          return normalize_glob(name) unless name.empty?

          text = msg.respond_to?(:text) ? msg.text.to_s : ""
          _header, tool_name, = tool_header_and_body(text)
          normalize_glob(tool_name.to_s)
        rescue StandardError
          ""
        end

        def tool_header_and_body(text)
          first_line, rest = text.to_s.split("\n", 2)
          m = first_line&.match(/\A\[tool:\s*(?<name>.*?)\]\s*\z/)
          return [nil, nil, text.to_s] unless m

          [first_line, m[:name].to_s.strip, rest.to_s]
        rescue StandardError
          [nil, nil, text.to_s]
        end

        def boundary_index(messages)
          return 0 if messages.empty?
          boundary_user = boundary_index_by_recent_user_turns(messages)
          boundary_assistant = boundary_index_by_recent_assistants(messages)

          if boundary_assistant.nil?
            boundary_user
          else
            [boundary_user, boundary_assistant].min
          end
        rescue StandardError
          0
        end

        def boundary_index_by_recent_user_turns(messages)
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

        def boundary_index_by_recent_assistants(messages)
          return messages.length if keep_last_assistant_messages == 0

          seen = 0
          (messages.length - 1).downto(0) do |idx|
            msg = messages[idx]
            next unless msg.respond_to?(:assistant?) && msg.assistant?

            seen += 1
            return idx if seen == keep_last_assistant_messages
          end

          nil
        rescue StandardError
          nil
        end

        def prune_start_index(messages)
          messages.each_with_index do |msg, idx|
            next unless msg.respond_to?(:user?) && msg.user?

            return idx
          end

          messages.length
        rescue StandardError
          messages.length
        end

        def maybe_soft_trim_message(msg)
          return msg unless prune_candidate?(msg)

          text = msg.respond_to?(:text) ? msg.text.to_s : msg.to_s
          header, _tool_name, body = tool_header_and_body(text)
          return msg unless tool_prunable?(tool_name_for_matching(msg))

          raw_len = body.length
          return msg if raw_len <= soft_trim_max_chars

          head_chars = soft_trim_head_chars
          tail_chars = soft_trim_tail_chars
          return msg if head_chars + tail_chars >= raw_len

          head = body[0, head_chars].to_s
          tail = tail_chars <= 0 ? "" : body[-tail_chars, tail_chars].to_s

          trimmed = "#{head}\n...\n#{tail}"

          note = "[Tool result trimmed: kept first #{head_chars} chars and last #{tail_chars} chars of #{raw_len} chars.]"

          replacement =
            if header
              "#{header}\n#{trimmed}\n\n#{note}"
            else
              "#{trimmed}\n\n#{note}"
            end

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
