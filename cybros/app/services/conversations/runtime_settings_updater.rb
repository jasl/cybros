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
        apply_agent_program_selection! if attributes.key?(:agent_program_id)
        apply_execution_target_selection! if attributes.key?(:default_execution_target_id)
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

      def apply_agent_program_selection!
        program = resolve_agent_program(attributes.fetch(:agent_program_id))
        conversation.agent_program = program
        conversation.agent_config_schema_fingerprint = program.config_schema_fingerprint
      end

      def apply_execution_target_selection!
        conversation.default_execution_target = resolve_execution_target(attributes.fetch(:default_execution_target_id))
      end

      def resolve_agent_program(raw_id)
        id = raw_id.to_s.strip
        if id.empty?
          AgentCore::ValidationError.raise!(
            "Agent selection is required.",
            code: "cybros.conversations.agent_program_required",
          )
        end
        return conversation.agent_program if conversation.agent_program_id.to_s == id

        program = AgentProgram.find_by(id: id)
        unless program
          AgentCore::ValidationError.raise!(
            "Selected agent could not be found.",
            code: "cybros.conversations.agent_program_not_found",
            details: { agent_program_id: id },
          )
        end

        return program if program.selectable_for_conversation?

        AgentCore::ValidationError.raise!(
          "Selected agent is not currently active and healthy.",
          code: "cybros.conversations.agent_program_not_selectable",
          details: { agent_program_id: program.id },
        )
      end

      def resolve_execution_target(raw_id)
        id = raw_id.to_s.strip
        return nil if id.empty?
        return conversation.default_execution_target if conversation.default_execution_target_id.to_s == id

        target = ExecutionTarget.includes(:execution_location, :workspace).find_by(id: id)
        unless target
          AgentCore::ValidationError.raise!(
            "Selected execution target could not be found.",
            code: "cybros.conversations.execution_target_not_found",
            details: { execution_target_id: id },
          )
        end

        return target if RuntimeGovernance::ExecutionTargetSwitchPolicy.visible_target?(target)

        AgentCore::ValidationError.raise!(
          "Selected execution target is not currently visible.",
          code: "cybros.conversations.execution_target_not_selectable",
          details: { execution_target_id: target.id },
        )
      end
  end
end
