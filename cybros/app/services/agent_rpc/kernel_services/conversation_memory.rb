module AgentRPC
  module KernelServices
    class ConversationMemory
      MEMORY_KEY = "cybros.conversation_memory.document".freeze

      def self.get(conversation:)
        new(conversation: conversation).get
      end

      def self.put!(conversation:, body:)
        new(conversation: conversation).put!(body: body)
      end

      def self.append!(conversation:, text:)
        new(conversation: conversation).append!(text: text)
      end

      def initialize(conversation:)
        @conversation = conversation
      end

      def get
        document_response(body: current_body)
      end

      def put!(body:)
        persisted_body = body.to_s

        root_conversation.with_lock do
          entry = storage_lane.lane_kv_entries.find_or_initialize_by(key: MEMORY_KEY)
          entry.value = document_value(body: persisted_body)
          entry.save!
        end

        document_response(body: persisted_body)
      end

      def append!(text:)
        persisted_body = nil

        root_conversation.with_lock do
          entry = storage_lane.lane_kv_entries.find_or_initialize_by(key: MEMORY_KEY)
          persisted_body = extract_body(entry) + text.to_s
          entry.value = document_value(body: persisted_body)
          entry.save!
        end

        document_response(body: persisted_body)
      end

      private

        attr_reader :conversation

        def root_conversation
          conversation.root_conversation || conversation
        end

        def storage_lane
          root_conversation.chat_lane
        end

        def current_body
          extract_body(storage_lane.lane_kv_entries.find_by(key: MEMORY_KEY))
        end

        def extract_body(entry)
          value = entry&.value
          return value.fetch("body", "").to_s if value.is_a?(Hash)

          value.to_s
        end

        def document_value(body:)
          {
            "kind" => "conversation_memory",
            "body" => body.to_s,
          }
        end

        def document_response(body:)
          {
            "document" => {
              "kind" => "conversation_memory",
              "body" => body.to_s,
            },
          }
        end
    end
  end
end
