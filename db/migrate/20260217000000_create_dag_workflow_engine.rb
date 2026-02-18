class CreateDAGWorkflowEngine < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_graphs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :attachable, type: :uuid, polymorphic: true, index: { unique: true }

      t.timestamps
    end

    create_table :dag_node_bodies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :type, null: false
      t.jsonb :input, null: false, default: {}
      t.jsonb :output, null: false, default: {}
      t.jsonb :output_preview, null: false, default: {}

      t.timestamps
    end

    create_table :dag_nodes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, type: :uuid, foreign_key: { to_table: :dag_graphs }, null: false
      t.index %i[graph_id state node_type], name: "index_dag_nodes_lookup"
      t.index %i[graph_id created_at], name: "index_dag_nodes_created_at"
      t.index %i[graph_id compressed_at], name: "index_dag_nodes_compressed_at"
      t.index %i[graph_id retry_of_id], name: "index_dag_nodes_retry_of"

      t.string :node_type, null: false
      t.string :state, null: false
      t.jsonb :metadata, null: false, default: {}
      t.check_constraint(
        "state IN ('pending','running','finished','errored','rejected','skipped','cancelled')",
        name: "check_dag_nodes_state_enum"
      )

      t.uuid :turn_id, null: false, default: -> { "uuidv7()" }
      t.index %i[graph_id turn_id], name: "index_dag_nodes_turn"

      t.references :body, type: :uuid, null: false,
                   foreign_key: { to_table: :dag_node_bodies },
                   index: { unique: true }

      t.references :retry_of, type: :uuid, foreign_key: { to_table: :dag_nodes }

      t.references :compressed_by, type: :uuid, foreign_key: { to_table: :dag_nodes }
      t.datetime :compressed_at

      t.datetime :context_excluded_at
      t.datetime :deleted_at
      t.check_constraint(
        "context_excluded_at IS NULL OR state IN ('finished','errored','rejected','skipped','cancelled')",
        name: "check_dag_nodes_context_excluded_terminal"
      )
      t.check_constraint(
        "deleted_at IS NULL OR state IN ('finished','errored','rejected','skipped','cancelled')",
        name: "check_dag_nodes_deleted_terminal"
      )

      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    create_table :dag_node_visibility_patches, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }
      t.references :node, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_nodes, on_delete: :cascade }
      t.datetime :context_excluded_at
      t.datetime :deleted_at
      t.timestamps

      t.index %i[graph_id node_id], unique: true, name: "index_dag_visibility_patches_uniqueness"
    end

    create_table :dag_edges, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, type: :uuid, foreign_key: { to_table: :dag_graphs }, null: false
      t.index %i[graph_id from_node_id to_node_id edge_type], unique: true,
              name: "index_dag_edges_uniqueness"
      t.index %i[graph_id from_node_id], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_from"
      t.index %i[graph_id to_node_id], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_to"
      t.index %i[graph_id edge_type], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_type"

      t.references :from_node, type: :uuid, foreign_key: { to_table: :dag_nodes }, null: false
      t.references :to_node, type: :uuid, foreign_key: { to_table: :dag_nodes }, null: false
      t.check_constraint "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"

      t.string :edge_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.check_constraint(
        "edge_type IN ('sequence','dependency','branch')",
        name: "check_dag_edges_edge_type_enum"
      )

      t.datetime :compressed_at
      t.timestamps
    end
  end
end
