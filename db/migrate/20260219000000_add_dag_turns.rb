class AddDAGTurns < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_turns, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }
      t.uuid :lane_id, null: false

      t.uuid :anchor_node_id
      t.datetime :anchor_created_at
      t.check_constraint(
        "((anchor_node_id IS NULL) = (anchor_created_at IS NULL))",
        name: "check_dag_turns_anchor_fields_consistent"
      )

      t.jsonb :metadata, null: false, default: {}

      t.timestamps

      t.index %i[graph_id lane_id], name: "index_dag_turns_graph_lane"
      t.index %i[graph_id lane_id id], unique: true, name: "index_dag_turns_graph_lane_id_unique"
      t.index %i[graph_id lane_id anchor_created_at anchor_node_id],
              where: "anchor_node_id IS NOT NULL",
              name: "index_dag_turns_graph_lane_anchor"
    end

    add_foreign_key :dag_turns, :dag_lanes,
                    column: %i[graph_id lane_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_turns_lane_graph_scoped",
                    on_delete: :cascade

    reversible do |dir|
      dir.up do
        execute(<<~SQL.squish)
          INSERT INTO dag_turns (id, graph_id, lane_id, metadata, created_at, updated_at)
          SELECT DISTINCT n.turn_id, n.graph_id, n.lane_id, '{}'::jsonb, NOW(), NOW()
          FROM dag_nodes n
          WHERE n.turn_id IS NOT NULL
          ON CONFLICT (id) DO NOTHING
        SQL

        execute(<<~SQL.squish)
          WITH anchors AS (
            SELECT DISTINCT ON (n.graph_id, n.lane_id, n.turn_id)
              n.graph_id,
              n.lane_id,
              n.turn_id,
              n.id AS anchor_node_id,
              n.created_at AS anchor_created_at
            FROM dag_nodes n
            WHERE n.node_type IN ('user_message','agent_message','character_message')
            ORDER BY n.graph_id, n.lane_id, n.turn_id, n.created_at ASC, n.id ASC
          )
          UPDATE dag_turns t
             SET anchor_node_id = a.anchor_node_id,
                 anchor_created_at = a.anchor_created_at,
                 updated_at = NOW()
            FROM anchors a
           WHERE t.graph_id = a.graph_id
             AND t.lane_id = a.lane_id
             AND t.id = a.turn_id
        SQL
      end
    end

    add_foreign_key :dag_nodes, :dag_turns,
                    column: %i[graph_id lane_id turn_id],
                    primary_key: %i[graph_id lane_id id],
                    name: "fk_dag_nodes_turn_graph_scoped",
                    deferrable: :deferred
  end
end
