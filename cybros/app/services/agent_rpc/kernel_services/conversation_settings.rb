module AgentRpc
  module KernelServices
    class ConversationSettings
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
        { "settings" => conversation.public_settings }
      end

      def update!(patch:)
        normalized_patch = normalize_hash(patch)

        draft.with_lock do
          draft.staged_public_settings_patch = draft.staged_public_settings_patch.deep_merge(normalized_patch)
          draft.save!
        end

        { "staged_public_settings_patch" => draft.reload.staged_public_settings_patch }
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
