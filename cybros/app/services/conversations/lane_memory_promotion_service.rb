module Conversations
  class LaneMemoryPromotionService
    CURATED_TARGET = AgentRPC::KernelServices::WorkspaceMemory::DEFAULT_TARGET
    BRANCH_PROMOTION_TARGET = "memory/branch.md".freeze

    def self.daily_log_target(date: Date.current)
      "memory/#{date.strftime("%Y-%m-%d")}.md"
    end

    def self.promote_for_branch!(conversation:, lane:)
      new(conversation: conversation, lane: lane).promote_for_branch!
    end

    def initialize(conversation:, lane:)
      @conversation = conversation
      @lane = lane || conversation.chat_lane
    end

    def promote_for_branch!
      lane_body = read_body(scope: "lane", target: BRANCH_PROMOTION_TARGET)
      return result(promoted: false, reason: "lane_memory_blank") if lane_body.strip.empty?

      conversation_body = read_body(scope: "conversation", target: CURATED_TARGET)
      merged_body = merge_curated_memory(conversation_body:, lane_body:)
      return result(promoted: false, reason: "already_promoted") if merged_body == conversation_body

      AgentRPC::KernelServices::WorkspaceMemory.put!(
        conversation: conversation,
        lane: lane,
        scope: "conversation",
        target: CURATED_TARGET,
        body: merged_body,
      )

      result(promoted: true, reason: "lane_memory_promoted")
    end

    private

      attr_reader :conversation, :lane

      def read_body(scope:, target:)
        AgentRPC::KernelServices::WorkspaceMemory.get(
          conversation: conversation,
          lane: lane,
          scope: scope,
          target: target,
        ).dig("document", "body").to_s
      end

      def merge_curated_memory(conversation_body:, lane_body:)
        normalized_lane = lane_body.strip
        return conversation_body if normalized_lane.empty?
        return lane_body if conversation_body.strip.empty?
        return conversation_body if conversation_body.include?(normalized_lane)

        "#{conversation_body.rstrip}\n\n#{lane_body.lstrip}"
      end

      def result(promoted:, reason:)
        {
          "promoted" => promoted,
          "scope" => "conversation",
          "target" => CURATED_TARGET,
          "reason" => reason,
        }
      end
  end
end
