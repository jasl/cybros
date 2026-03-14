module Conversations
  class RuntimeSettingsUpdater
    def self.update!(conversation:, attributes:)
      new(conversation: conversation, attributes: attributes).update!
    end

    def initialize(conversation:, attributes:)
      @conversation = conversation
      @attributes = attributes.to_h.deep_symbolize_keys
    end

    def update!
      conversation.transaction do
        apply_agent_selection! if attributes.key?(:agent_id)
        conversation.permission_mode = attributes.fetch(:permission_mode) if attributes.key?(:permission_mode)

        return conversation if conversation.save

        AgentCore::ValidationError.raise!(
          conversation.errors.full_messages.to_sentence,
          code: "cybros.conversations.runtime_settings_invalid",
          details: { errors: conversation.errors.to_hash(true) },
        )
      end
    end

    private

      attr_reader :conversation, :attributes

      def apply_agent_selection!
        agent = resolve_agent(attributes.fetch(:agent_id))
        conversation.agent = agent
        conversation.agent_config_schema_fingerprint = agent.config_schema_fingerprint
        conversation.metadata = updated_metadata_for(agent)
      end

      def resolve_agent(raw_id)
        id = raw_id.to_s.strip
        if id.empty?
          AgentCore::ValidationError.raise!(
            "Agent selection is required.",
            code: "cybros.conversations.agent_required",
          )
        end
        return conversation.agent if conversation.agent_id.to_s == id

        agent = Agent.find_by(id: id)
        unless agent
          AgentCore::ValidationError.raise!(
            "Selected agent could not be found.",
            code: "cybros.conversations.agent_not_found",
            details: { agent_id: id },
          )
        end

        return agent if agent.selectable_for_conversation?

        AgentCore::ValidationError.raise!(
          "Selected agent is not currently active and healthy.",
          code: "cybros.conversations.agent_not_selectable",
          details: { agent_id: agent.id },
        )
      end

      def updated_metadata_for(agent)
        metadata = conversation.metadata.is_a?(Hash) ? conversation.metadata.deep_stringify_keys : {}
        existing_agent_metadata = metadata["agent"].is_a?(Hash) ? metadata["agent"].deep_dup : {}

        metadata.merge(
          "agent" => existing_agent_metadata.except("key").merge(agent.conversation_metadata_fragment),
        )
      end
  end
end
