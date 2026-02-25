# frozen_string_literal: true

module AgentCore
  # Unified message format used throughout AgentCore.
  #
  # Follows Anthropic-style content blocks for maximum expressiveness.
  # Can be converted to OpenAI format when needed by providers.
  #
  # @example Simple text message
  #   Message.new(role: :user, content: "Hello!")
  #
  # @example Assistant message with tool calls
  #   Message.new(
  #     role: :assistant,
  #     content: [TextContent.new(text: "Let me check that.")],
  #     tool_calls: [ToolCall.new(id: "tc_1", name: "read", arguments: { "path" => "config.json" })]
  #   )
  class Message
    ROLES = %i[system user assistant tool_result].freeze

    attr_reader :role, :content, :tool_calls, :tool_call_id, :name, :metadata

    def initialize(role:, content:, tool_calls: nil, tool_call_id: nil, name: nil, metadata: nil)
      @role = validate_role!(role)
      @content = content.freeze
      @tool_calls = tool_calls&.freeze
      @tool_call_id = tool_call_id
      @name = name
      @metadata = (metadata || {}).freeze
    end

    def system? = role == :system
    def user? = role == :user
    def assistant? = role == :assistant
    def tool_result? = role == :tool_result

    # Returns text content as a single string.
    # For array content, concatenates all TextContent blocks.
    def text
      case content
      when String
        content
      when Array
        content.filter_map { |block| block.text if block.respond_to?(:text) }.join
      else
        content.to_s
      end
    end

    # Whether this assistant message contains tool calls.
    def has_tool_calls?
      tool_calls && !tool_calls.empty?
    end

    # Convert to a plain Hash for serialization.
    def to_h
      h = { role: role, content: serialize_content }
      h[:tool_calls] = tool_calls.map(&:to_h) if has_tool_calls?
      h[:tool_call_id] = tool_call_id if tool_call_id
      h[:name] = name if name
      h[:metadata] = metadata unless metadata.empty?
      h
    end

    def ==(other)
      other.is_a?(Message) &&
        role == other.role &&
        content == other.content &&
        tool_calls == other.tool_calls &&
        tool_call_id == other.tool_call_id &&
        name == other.name &&
        metadata == other.metadata
    end

    # Build a Message from a serialized Hash.
    def self.from_h(hash)
      ValidationError.raise!(
        "message must be a Hash (got #{hash.class})",
        code: "agent_core.message.message_must_be_a_hash_got",
        details: { value_class: hash.class.name },
      ) unless hash.is_a?(Hash)

      role = hash.fetch("role", hash.fetch(:role, nil))
      content = deserialize_content(hash.fetch("content", hash.fetch(:content, nil)))

      tool_calls =
        if hash.key?("tool_calls") || hash.key?(:tool_calls)
          raw = hash.fetch("tool_calls", hash.fetch(:tool_calls, nil))
          ValidationError.raise!(
            "tool_calls must be an Array",
            code: "agent_core.message.tool_calls_must_be_an_array",
            details: { tool_calls_class: raw.class.name },
          ) unless raw.is_a?(Array)

          raw.map { |tc| ToolCall.from_h(tc) }
        end

      tool_call_id = hash.fetch("tool_call_id", hash.fetch(:tool_call_id, nil))
      name = hash.fetch("name", hash.fetch(:name, nil))

      metadata = hash.fetch("metadata", hash.fetch(:metadata, {}))
      metadata = {} unless metadata.is_a?(Hash)

      new(
        role: role,
        content: content,
        tool_calls: tool_calls,
        tool_call_id: tool_call_id,
        name: name,
        metadata: metadata
      )
    end

    private

    def validate_role!(role)
      ValidationError.raise!(
        "Role cannot be nil. Must be one of: #{ROLES.join(", ")}",
        code: "agent_core.message.role_cannot_be_nil_must_be_one_of",
        details: { roles: ROLES.map(&:to_s).sort },
      ) if role.nil?

      sym = role.to_sym
      unless ROLES.include?(sym)
        ValidationError.raise!(
          "Invalid role: #{role}. Must be one of: #{ROLES.join(", ")}",
          code: "agent_core.message.invalid_role_must_be_one_of",
          details: { role: role.to_s, roles: ROLES.map(&:to_s).sort },
        )
      end
      sym
    end

    def serialize_content
      case content
      when String
        content
      when Array
        content.map(&:to_h)
      else
        content.to_s
      end
    end

    def self.deserialize_content(content)
      case content
      when String
        content
      when Array
        content.map { |block| ContentBlock.from_h(block) }
      else
        content.to_s
      end
    end
  end
end
