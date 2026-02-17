module DAG
  class TickConversationJob < ApplicationJob
    queue_as :dag

    DEFAULT_LIMIT = 10

      def perform(conversation_id, limit: DEFAULT_LIMIT)
        conversation = Conversation.find_by(id: conversation_id)
        return if conversation.nil?

        DAG::AdvisoryLock.with_try_lock(conversation_id) do
          DAG::FailurePropagation.propagate!(conversation_id: conversation_id)
          nodes = DAG::Scheduler.claim_executable_nodes(conversation_id: conversation_id, limit: limit)
          nodes.each do |node|
            DAG::ExecuteNodeJob.perform_later(node.id)
          end
        end
      end
  end
end
