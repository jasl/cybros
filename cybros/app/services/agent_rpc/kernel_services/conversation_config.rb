module AgentRpc
  module KernelServices
    class ConversationConfig
      def self.get(draft:)
        new(draft: draft).get
      end

      def self.update!(draft:, patch:)
        new(draft: draft).update!(patch: patch)
      end

      def initialize(draft:)
        @draft = draft
      end

      def get
        { "config" => conversation.selected_agent_config }
      end

      def update!(patch:)
        normalized_patch = normalize_hash(patch)

        draft.with_lock do
          draft.staged_agent_config_patch = draft.staged_agent_config_patch.deep_merge(normalized_patch)
          draft.save!
        end

        { "staged_agent_config_patch" => draft.reload.staged_agent_config_patch }
      end

      private

        attr_reader :draft

        def conversation
          draft.conversation
        end

        def normalize_hash(value)
          value.is_a?(Hash) ? value.deep_stringify_keys : {}
        end
    end
  end
end
