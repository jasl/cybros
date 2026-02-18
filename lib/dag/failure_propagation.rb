module DAG
  class FailurePropagation
    def self.propagate!(graph:)
      new(graph: graph).propagate!
    end

    def initialize(graph:)
      @graph = graph
      @graph_id = graph.id
    end

    def propagate!
      loop do
        updated_ids = propagate_once!
        updated_ids.each do |node_id|
          @graph.emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
            subject_type: "DAG::Node",
            subject_id: node_id,
            particulars: { "from" => "pending", "to" => "skipped" }
          )
        end
        break if updated_ids.empty?
      end
    end

    private

      def propagate_once!
        now = Time.current
        updated_ids = []

        DAG::Node.with_connection do |connection|
          graph_quoted = connection.quote(@graph_id)
          now_quoted = connection.quote(now)

          sql = <<~SQL
            WITH blocked AS (
              SELECT child.id AS node_id,
                     jsonb_agg(
                       jsonb_build_object(
                         'node_id', parent.id,
                         'state', parent.state,
                         'edge_id', e.id
                       )
                       ORDER BY parent.id
                     ) AS blocked_by
              FROM dag_nodes child
              JOIN dag_edges e
                ON e.graph_id = child.graph_id
               AND e.to_node_id = child.id
               AND e.edge_type = 'dependency'
               AND e.compressed_at IS NULL
              JOIN dag_nodes parent
                ON parent.id = e.from_node_id
               AND parent.graph_id = e.graph_id
               AND parent.compressed_at IS NULL
              WHERE child.graph_id = #{graph_quoted}
                AND child.compressed_at IS NULL
                AND child.state = 'pending'
                AND parent.state IN ('errored', 'rejected', 'skipped', 'cancelled')
              GROUP BY child.id
            )
            UPDATE dag_nodes
               SET state = 'skipped',
                   finished_at = #{now_quoted},
                   metadata = dag_nodes.metadata || jsonb_build_object(
                     'reason', 'blocked_by_failed_dependencies',
                     'blocked_by', blocked.blocked_by
                   ),
                   updated_at = #{now_quoted}
            FROM blocked
            WHERE dag_nodes.id = blocked.node_id
            RETURNING dag_nodes.id
          SQL

          updated_ids = connection.select_values(sql)
        end

        updated_ids
      end
  end
end
