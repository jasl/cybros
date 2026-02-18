module DAG
  class ExecuteNodeJob < ApplicationJob
    queue_as :dag

    def perform(node_id)
      DAG::Runner.run_node!(node_id, execute_job_id: job_id)
    end
  end
end
