class ConversationRunTracker
  class << self
    def mark_running_for_node!(node, at: Time.current)
      run = latest_run_for(node)
      return if run.nil?

      run.mark_running!(at: at)
      Automations::RunStateRecorder.running!(automation_run: run.automation_run) if run.automation_run.present?
    end

    def mark_terminal_for_node!(node, at: Time.current)
      run = latest_run_for(node)
      return if run.nil?

      case node.state
      when DAG::Node::FINISHED
        run.mark_succeeded!(at: at)
        Automations::RunStateRecorder.completed!(automation_run: run.automation_run) if run.automation_run.present?
      when DAG::Node::ERRORED
        run.mark_failed!(message: node.metadata.fetch("error", "errored").to_s, at: at)
        if run.automation_run.present?
          Automations::RunStateRecorder.failed!(
            automation_run: run.automation_run,
            failure: {
              "class" => "DAG::Node",
              "message" => node.metadata.fetch("error", "errored").to_s,
            },
          )
        end
      when DAG::Node::STOPPED, DAG::Node::REJECTED
        run.mark_canceled!(at: at)
        Automations::RunStateRecorder.canceled!(automation_run: run.automation_run) if run.automation_run.present?
      end
    end

    private

      def latest_run_for(node)
        ConversationRun.where(dag_node_id: node.id).order(:id).last
      end
  end
end
