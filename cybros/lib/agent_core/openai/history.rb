module AgentCore
  module OpenAI
    module History
      module_function

      def coerce_messages(value)
        Array(value).map { |msg| coerce_message(msg) }
      end

      def coerce_message(value)
        return value if value.is_a?(AgentCore::Message)
        return coerce_hash_message(value) if value.is_a?(Hash)

        if value.respond_to?(:role) && value.respond_to?(:content)
          role = normalize_role(value.role)
          content = value.content.to_s
          name = value.respond_to?(:name) ? value.name : nil
          tool_call_id = value.respond_to?(:tool_call_id) ? value.tool_call_id : nil
          metadata = value.respond_to?(:metadata) ? value.metadata : nil

          tool_calls = value.respond_to?(:tool_calls) ? value.tool_calls : nil
          tool_calls = coerce_tool_calls(tool_calls) if tool_calls

          return AgentCore::Message.new(
            role: role,
            content: content,
            tool_calls: tool_calls,
            tool_call_id: tool_call_id,
            name: name,
            metadata: metadata,
          )
        end

        ValidationError.raise!(
          "history messages must be AgentCore::Message or Hash-like with role/content",
          code: "agent_core.openai.history.history_messages_must_be_agentcore_message_or_hash_like_with_role_content",
          details: { value_class: value.class.name },
        )
      end

      def coerce_hash_message(hash)
        h = AgentCore::Utils.symbolize_keys(hash)

        role = normalize_role(h.fetch(:role, nil))
        content = h.fetch(:content, nil).to_s
        name = h.fetch(:name, nil)
        tool_call_id = h.fetch(:tool_call_id, nil)
        metadata = h.fetch(:metadata, nil)

        tool_calls = h.fetch(:tool_calls, nil)
        tool_calls = coerce_tool_calls(tool_calls) if tool_calls

        AgentCore::Message.new(
          role: role,
          content: content,
          tool_calls: tool_calls,
          tool_call_id: tool_call_id,
          name: name,
          metadata: metadata,
        )
      end
      private_class_method :coerce_hash_message

      def coerce_tool_calls(value)
        calls = Array(value).map.with_index(1) do |raw, idx|
          coerce_tool_call(raw, fallback_id: "tc_#{idx}")
        end

        calls.empty? ? nil : calls
      end
      private_class_method :coerce_tool_calls

      def coerce_tool_call(value, fallback_id:)
        return value if value.is_a?(AgentCore::ToolCall)

        ValidationError.raise!(
          "tool_calls entries must be Hash-like",
          code: "agent_core.openai.history.tool_calls_entries_must_be_hash_like",
          details: { value_class: value.class.name },
        ) unless value.is_a?(Hash)

        h = AgentCore::Utils.symbolize_keys(value)

        if h.key?(:name) && h.key?(:arguments)
          return AgentCore::ToolCall.from_h(h)
        end

        fn = AgentCore::Utils.symbolize_keys(h.fetch(:function, nil))
        name = fn.fetch(:name, "").to_s.strip
        ValidationError.raise!(
          "tool_call.function.name is required",
          code: "agent_core.openai.history.tool_call_function_name_is_required",
        ) if name.empty?

        raw_args = fn.fetch(:arguments, nil)
        args_hash, parse_error = AgentCore::Utils.parse_tool_arguments(raw_args)
        raw = parse_error ? raw_args.to_s : nil

        id = h.fetch(:id, nil).to_s.strip
        id = fallback_id if id.empty?

        AgentCore::ToolCall.new(
          id: id,
          name: name,
          arguments: args_hash,
          arguments_parse_error: parse_error,
          arguments_raw: raw,
        )
      end
      private_class_method :coerce_tool_call

      def normalize_role(value)
        str = value.to_s
        return :tool_result if str == "tool"

        sym = str.to_sym
        unless AgentCore::Message::ROLES.include?(sym)
          ValidationError.raise!(
            "Invalid message role: #{value.inspect}",
            code: "agent_core.openai.history.invalid_message_role",
            details: { role: value.to_s, role_inspect: value.inspect },
          )
        end

        sym
      end
      private_class_method :normalize_role
    end
  end
end
