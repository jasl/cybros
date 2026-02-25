module DAG
  class Scheduler
    def self.claim_executable_nodes(graph:, limit:, claimed_by:)
      new(graph: graph, limit: limit, claimed_by: claimed_by).claim_executable_nodes
    end

    def initialize(graph:, limit:, claimed_by:)
      @graph = graph
      @graph_id = graph.id
      @limit = Integer(limit)
      @claimed_by = claimed_by.to_s
    end

    def claim_executable_nodes
      node_ids = []
      now = Time.current
      lease_seconds = @graph.claim_lease_seconds_for(nil)
      lease_expires_at = now + lease_seconds

      DAG::Node.with_connection do |connection|
        DAG::Node.transaction do
          graph_quoted = connection.quote(@graph_id)

          sql = <<~SQL
            SELECT dag_nodes.id
            FROM dag_nodes
            WHERE dag_nodes.graph_id = #{graph_quoted}
              AND dag_nodes.state = 'pending'
              AND dag_nodes.compressed_at IS NULL
              AND NOT EXISTS (
                SELECT 1
                FROM dag_edges
                JOIN dag_nodes AS parents
                  ON parents.id = dag_edges.from_node_id
                 AND parents.graph_id = dag_edges.graph_id
                WHERE dag_edges.graph_id = dag_nodes.graph_id
                  AND dag_edges.to_node_id = dag_nodes.id
                  AND dag_edges.edge_type IN ('sequence', 'dependency')
                  AND dag_edges.compressed_at IS NULL
                  AND parents.compressed_at IS NULL
                  AND (
                    (
                      dag_edges.edge_type = 'sequence'
                      AND parents.state NOT IN ('finished', 'errored', 'rejected', 'skipped', 'stopped')
                    )
                    OR (
                      dag_edges.edge_type = 'dependency'
                      AND parents.state <> 'finished'
                    )
                  )
              )
            ORDER BY dag_nodes.id
            FOR UPDATE SKIP LOCKED
            LIMIT #{@limit}
          SQL

          node_ids = connection.select_values(sql)
          if node_ids.any?
            DAG::Node.where(id: node_ids, state: DAG::Node::PENDING).update_all(
              state: DAG::Node::RUNNING,
              started_at: nil,
              claimed_at: now,
              claimed_by: @claimed_by,
              lease_expires_at: lease_expires_at,
              heartbeat_at: nil,
              updated_at: now
            )

            node_ids = DAG::Node.where(id: node_ids, state: DAG::Node::RUNNING).order(:id).pluck(:id)
          end
        end
      end

      node_ids.each do |node_id|
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
          subject_type: "DAG::Node",
          subject_id: node_id,
          particulars: { "from" => "pending", "to" => "running" }
        )
      end

      DAG::Node.where(id: node_ids).order(:id).to_a
    end
  end
end
