module DAG
  class TickGraphJob < ApplicationJob
    queue_as :dag

    DEFAULT_LIMIT = 10

    def perform(graph_id, limit: DEFAULT_LIMIT)
      graph = DAG::Graph.find_by(id: graph_id)
      return if graph.nil?

      graph.with_graph_try_lock do
        DAG::FailurePropagation.propagate!(graph: graph)
        nodes = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: limit)
        nodes.each do |node|
          DAG::ExecuteNodeJob.perform_later(node.id)
        end
      end
    end
  end
end
