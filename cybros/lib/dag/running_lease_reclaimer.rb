module DAG
  class RunningLeaseReclaimer
    def self.reclaim!(graph:, now: Time.current)
      new(graph: graph, now: now).reclaim!
    end

    def initialize(graph:, now:)
      @graph = graph
      @graph_id = graph.id
      @now = now
    end

    def reclaim!
      node_ids = reclaim_once
      node_ids.each do |node_id|
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
          subject_type: "DAG::Node",
          subject_id: node_id,
          particulars: { "from" => "running", "to" => "errored" }
        )
      end
      node_ids
    end

    private

      def reclaim_once
        now = @now
        node_ids = []

        DAG::Node.with_connection do |connection|
          graph_quoted = connection.quote(@graph_id)
          now_quoted = connection.quote(now)

          sql = <<~SQL
            UPDATE dag_nodes
               SET state = 'errored',
                   finished_at = #{now_quoted},
                   metadata = dag_nodes.metadata || jsonb_build_object('error', 'running_lease_expired'),
                   updated_at = #{now_quoted}
             WHERE dag_nodes.graph_id = #{graph_quoted}
               AND dag_nodes.compressed_at IS NULL
               AND dag_nodes.state = 'running'
               AND dag_nodes.lease_expires_at IS NOT NULL
               AND dag_nodes.lease_expires_at < #{now_quoted}
            RETURNING dag_nodes.id
          SQL

          node_ids = connection.select_values(sql)
        end

        node_ids
      end
  end
end
