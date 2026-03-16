module AgentRPC
  module KernelServices
    class ConversationMemory
      def self.get(conversation:, scope: "conversation", lane: nil, target: nil)
        new(conversation: conversation, scope: scope, lane: lane, target: target).get
      end

      def self.put!(conversation:, body:, scope: "conversation", lane: nil, target: nil)
        new(conversation: conversation, scope: scope, lane: lane, target: target).put!(body: body)
      end

      def self.append!(conversation:, text:, scope: "conversation", lane: nil, target: nil)
        new(conversation: conversation, scope: scope, lane: lane, target: target).append!(text: text)
      end

      def initialize(conversation:, scope:, lane:, target:)
        @conversation = conversation
        @scope = scope
        @lane = lane || conversation.chat_lane
        @target = target
      end

      def get
        WorkspaceMemory.get(conversation: conversation, lane: lane, scope: scope, target: target)
      end

      def put!(body:)
        WorkspaceMemory.put!(conversation: conversation, lane: lane, scope: scope, target: target, body: body)
      end

      def append!(text:)
        WorkspaceMemory.append!(conversation: conversation, lane: lane, scope: scope, target: target, text: text)
      end

      private

        attr_reader :conversation, :scope, :lane, :target
    end
  end
end
