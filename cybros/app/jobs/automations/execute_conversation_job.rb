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

          hydrate_dispatch_snapshot!(conversation)
          Automations::ExecutionStateRecorder.planning!(conversation: conversation)
          conversation.reload
        end
      end

      def automation_execution_status(conversation)
        conversation.metadata.dig("automation_execution", "status").to_s.presence || "queued"
      end

      def hydrate_dispatch_snapshot!(conversation)
        selected_model_ref = conversation.metadata.dig("llm", "model_ref").to_s.presence
        return conversation if selected_model_ref.present?

        selected_model_ref = conversation.automation&.task_payload&.fetch("selected_model_ref", "").to_s.presence
        return conversation if selected_model_ref.blank?

        conversation.update!(
          metadata: conversation.metadata.deep_merge("llm" => { "model_ref" => selected_model_ref }),
        )
      end
  end
end
