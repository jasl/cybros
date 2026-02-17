module DAG
  class TickConversationJob < ApplicationJob
    queue_as :dag

    DEFAULT_LIMIT = 10

    def perform(conversation_id, limit: DEFAULT_LIMIT)
      conversation = Conversation.find_by(id: conversation_id)
      return if conversation.nil?

      DAG::AdvisoryLock.with_try_lock(conversation_id) do
        nodes = DAG::Scheduler.claim_runnable_nodes(conversation_id: conversation_id, limit: limit)
        nodes.each do |node|
          DAG::ExecuteNodeJob.perform_later(node.id)
        end
      end
    end
  end
end
