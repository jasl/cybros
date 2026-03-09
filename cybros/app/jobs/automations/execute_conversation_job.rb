module Automations
  class ExecuteConversationJob < ApplicationJob
    queue_as :default

    def perform(conversation_id)
      conversation = claim_queued_conversation!(conversation_id)
      return if conversation.nil?

      Automations::ConversationOrchestrator.start!(conversation: conversation)
    rescue Exception => error
      Automations::ExecutionStateRecorder.failed!(conversation: conversation, error: error) if conversation.present?
      raise
    end

    private

      def claim_queued_conversation!(conversation_id)
        Conversation.transaction do
          conversation = Conversation.lock.find_by(id: conversation_id)
          next nil if conversation.nil? || conversation.automation_id.blank?
          next nil unless automation_execution_status(conversation) == "queued"

          Automations::ExecutionStateRecorder.planning!(conversation: conversation)
          conversation
        end
      end

      def automation_execution_status(conversation)
        conversation.metadata.dig("automation_execution", "status").to_s.presence || "queued"
      end
  end
end
