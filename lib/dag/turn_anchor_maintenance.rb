module DAG
  class TurnAnchorMaintenance
    def self.refresh_for_turn_ids!(graph:, lane_id:, turn_ids:)
      new(graph: graph).refresh_for_turn_ids!(lane_id: lane_id, turn_ids: turn_ids)
    end

    def initialize(graph:)
      @graph = graph
    end

    def refresh_for_turn_ids!(lane_id:, turn_ids:)
      turn_ids = Array(turn_ids).map(&:to_s).uniq
      return if turn_ids.empty?

      anchor_types = @graph.turn_anchor_node_types
      return if anchor_types.empty?

      DAG::Turn.with_connection do |connection|
        graph_quoted = connection.quote(@graph.id)
        lane_quoted = connection.quote(lane_id)
        now_quoted = connection.quote(Time.current)

        turn_id_values =
          turn_ids.map do |turn_id|
            "(#{connection.quote(turn_id)}::uuid)"
          end.join(",")

        type_list =
          anchor_types.map do |type|
            connection.quote(type.to_s)
          end.join(",")

        sql = <<~SQL
          WITH input_turn_ids(turn_id) AS (
            SELECT * FROM (VALUES #{turn_id_values}) AS t(turn_id)
          ),
          visible AS (
            SELECT DISTINCT ON (n.turn_id)
              n.turn_id,
              n.id AS anchor_node_id,
              n.created_at AS anchor_created_at
            FROM dag_nodes n
            WHERE n.graph_id = #{graph_quoted}
              AND n.lane_id = #{lane_quoted}
              AND n.turn_id IN (SELECT turn_id FROM input_turn_ids)
              AND n.compressed_at IS NULL
              AND n.deleted_at IS NULL
              AND n.node_type IN (#{type_list})
            ORDER BY n.turn_id, n.created_at ASC, n.id ASC
          ),
          including_deleted AS (
            SELECT DISTINCT ON (n.turn_id)
              n.turn_id,
              n.id AS anchor_node_id,
              n.created_at AS anchor_created_at
            FROM dag_nodes n
            WHERE n.graph_id = #{graph_quoted}
              AND n.lane_id = #{lane_quoted}
              AND n.turn_id IN (SELECT turn_id FROM input_turn_ids)
              AND n.compressed_at IS NULL
              AND n.node_type IN (#{type_list})
            ORDER BY n.turn_id, n.created_at ASC, n.id ASC
          ),
          updates AS (
            SELECT
              t.turn_id,
              v.anchor_node_id AS visible_anchor_node_id,
              v.anchor_created_at AS visible_anchor_created_at,
              d.anchor_node_id AS including_deleted_anchor_node_id,
              d.anchor_created_at AS including_deleted_anchor_created_at
            FROM input_turn_ids t
            LEFT JOIN visible v ON v.turn_id = t.turn_id
            LEFT JOIN including_deleted d ON d.turn_id = t.turn_id
          )
          UPDATE dag_turns
             SET anchor_node_id = updates.visible_anchor_node_id,
                 anchor_created_at = updates.visible_anchor_created_at,
                 anchor_node_id_including_deleted = updates.including_deleted_anchor_node_id,
                 anchor_created_at_including_deleted = updates.including_deleted_anchor_created_at,
                 updated_at = #{now_quoted}
           FROM updates
           WHERE dag_turns.graph_id = #{graph_quoted}
             AND dag_turns.lane_id = #{lane_quoted}
             AND dag_turns.id = updates.turn_id
        SQL

        connection.execute(sql)
      end
    end
  end
end
