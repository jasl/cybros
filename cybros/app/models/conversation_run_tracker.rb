class ConversationRunTracker
  class << self
    def mark_running_for_node!(node, at: Time.current)
      run = latest_run_for(node)
      return if run.nil?

      run.mark_running!(at: at)
      record_automation_execution!(run: run, status: :running)
    end

    def mark_terminal_for_node!(node, at: Time.current)
      run = latest_run_for(node)
      return if run.nil?

      case node.state
      when DAG::Node::FINISHED
        run.mark_succeeded!(at: at)
        record_automation_execution!(run: run, status: :completed)
      when DAG::Node::ERRORED
        run.mark_failed!(message: node.metadata.fetch("error", "errored").to_s, at: at)
        record_automation_execution!(
          run: run,
          status: :failed,
          failure: {
            "class" => "DAG::Node",
            "message" => node.metadata.fetch("error", "errored").to_s,
          },
        )
      when DAG::Node::STOPPED, DAG::Node::REJECTED
        run.mark_canceled!(at: at)
        record_automation_execution!(run: run, status: :canceled)
      end

      RuntimeGovernance::ExecutionCapacityEnforcer.release!(conversation_run: run) if run.execution_capacity_governed?
    end

    private

      def latest_run_for(node)
        ConversationRun.latest_for_node(node)
      end

      def record_automation_execution!(run:, status:, failure: nil)
        conversation = run.conversation
        return unless conversation&.respond_to?(:automation_id)
        return unless conversation.automation_id.present?

        case status
        when :running
          Automations::ExecutionStateRecorder.running!(conversation: conversation, conversation_run: run)
        when :completed
          Automations::ExecutionStateRecorder.completed!(conversation: conversation, conversation_run: run)
        when :failed
          Automations::ExecutionStateRecorder.failed!(conversation: conversation, conversation_run: run, failure: failure)
        when :canceled
          Automations::ExecutionStateRecorder.canceled!(conversation: conversation, conversation_run: run)
        end
      end
  end
end
