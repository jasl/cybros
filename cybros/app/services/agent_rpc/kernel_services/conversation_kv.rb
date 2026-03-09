module AgentRPC
  module KernelServices
    class ConversationKV
      def self.get(draft:, key:)
        new(draft: draft).get(key: key)
      end

      def self.set!(draft:, key:, value:)
        new(draft: draft).set!(key: key, value: value)
      end

      def self.delete!(draft:, key:)
        new(draft: draft).delete!(key: key)
      end

      def self.list(draft:, prefix: nil)
        new(draft: draft).list(prefix: prefix)
      end

      def initialize(draft:)
        @draft = draft
      end

      def get(key:)
        entry = conversation.conversation_kv_entries.find_by(key: normalize_key(key))
        { "entry" => serialize_entry(entry) }
      end

      def set!(key:, value:)
        operation = { "op" => "set", "key" => normalize_key(key), "value" => normalize_value(value) }
        append_operation!(operation)
        { "staged_kv_ops" => draft.reload.staged_kv_ops }
      end

      def delete!(key:)
        operation = { "op" => "delete", "key" => normalize_key(key) }
        append_operation!(operation)
        { "staged_kv_ops" => draft.reload.staged_kv_ops }
      end

      def list(prefix: nil)
        entries = conversation.conversation_kv_entries.order(:key)
        normalized_prefix = prefix.to_s
        entries = entries.where("key LIKE ?", "#{normalized_prefix}%") if normalized_prefix.present?

        { "entries" => entries.map { |entry| serialize_entry(entry) } }
      end

      private

        attr_reader :draft

        def append_operation!(operation)
          draft.with_lock do
            draft.staged_kv_ops = Array(draft.staged_kv_ops) + [operation]
            draft.save!
          end
        end

        def conversation
          draft.bound_conversation
        end

        def normalize_key(key)
          key.to_s.strip
        end

        def normalize_value(value)
          case value
          when Hash
            value.deep_stringify_keys
          when Array
            value.map { |element| normalize_value(element) }
          else
            value
          end
        end

        def serialize_entry(entry)
          return nil if entry.nil?

          {
            "key" => entry.key,
            "value" => entry.value,
          }
        end
    end
  end
end
