class AddDAGTurns < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_turns, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }
      t.uuid :subgraph_id, null: false

      t.bigint :anchored_seq
      t.check_constraint(
        "anchored_seq IS NULL OR anchored_seq > 0",
        name: "check_dag_turns_anchored_seq_positive"
      )

      t.uuid :anchor_node_id
      t.datetime :anchor_created_at
      t.check_constraint(
        "((anchor_node_id IS NULL) = (anchor_created_at IS NULL))",
        name: "check_dag_turns_anchor_fields_consistent"
      )

      t.uuid :anchor_node_id_including_deleted
      t.datetime :anchor_created_at_including_deleted
      t.check_constraint(
        "((anchor_node_id_including_deleted IS NULL) = (anchor_created_at_including_deleted IS NULL))",
        name: "check_dag_turns_anchor_including_deleted_fields_consistent"
      )

      t.jsonb :metadata, null: false, default: {}

      t.timestamps

      t.index %i[graph_id subgraph_id], name: "index_dag_turns_graph_subgraph"
      t.index %i[graph_id subgraph_id id], unique: true, name: "index_dag_turns_graph_subgraph_id_unique"

      t.index %i[graph_id subgraph_id anchored_seq],
              unique: true,
              where: "anchored_seq IS NOT NULL",
              name: "index_dag_turns_graph_subgraph_anchored_seq_unique"

      t.index %i[graph_id subgraph_id id],
              where: "anchor_node_id IS NOT NULL",
              name: "index_dag_turns_graph_subgraph_visible"

      t.index %i[graph_id id],
              where: "anchor_node_id IS NOT NULL",
              name: "index_dag_turns_graph_visible"
    end

    add_foreign_key :dag_turns, :dag_subgraphs,
                    column: %i[graph_id subgraph_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_turns_subgraph_graph_scoped",
                    on_delete: :cascade

    add_foreign_key :dag_nodes, :dag_turns,
                    column: %i[graph_id subgraph_id turn_id],
                    primary_key: %i[graph_id subgraph_id id],
                    name: "fk_dag_nodes_turn_graph_scoped",
                    deferrable: :deferred
  end
end
