module DAG
  class TickGraphJob < ApplicationJob
    queue_as :dag

    DEFAULT_LIMIT = 10

    def perform(graph_id, limit: DEFAULT_LIMIT)
      graph = DAG::Graph.find_by(id: graph_id)
      return if graph.nil?

      graph.with_graph_try_lock do
        DAG::RunningLeaseReclaimer.reclaim!(graph: graph)
        DAG::FailurePropagation.propagate!(graph: graph)
        graph.apply_visibility_patches_if_idle!
        nodes = DAG::Scheduler.claim_executable_nodes(
          graph: graph,
          limit: limit,
          claimed_by: "tick_graph_job:#{job_id}"
        )
        if nodes.any?
          nodes.each do |node|
            DAG::ExecuteNodeJob.perform_later(node.id)
          end
        elsif (next_claim_at = next_claim_after_at(graph: graph))
          self.class.set(wait_until: next_claim_at).perform_later(graph.id, limit: limit)
        end
      end
    end

    private

      def next_claim_after_at(graph:)
        graph.nodes.active
          .where(state: DAG::Node::PENDING)
          .where.not(claim_after_at: nil)
          .where("claim_after_at > ?", Time.current)
          .minimum(:claim_after_at)
      end
  end
end
