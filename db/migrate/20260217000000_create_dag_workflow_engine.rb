class CreateDAGWorkflowEngine < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_graphs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :attachable, type: :uuid, polymorphic: true, index: { unique: true }

      t.timestamps
    end

    create_table :dag_subgraphs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }
      t.index %i[graph_id role], name: "index_dag_subgraphs_graph_role"

      t.string :role, null: false
      t.check_constraint(
        "role IN ('main','branch')",
        name: "check_dag_subgraphs_role_enum"
      )

      t.uuid :parent_subgraph_id
      t.check_constraint(
        "parent_subgraph_id IS NULL OR parent_subgraph_id <> id",
        name: "check_dag_subgraphs_no_self_parent"
      )

      t.uuid :forked_from_node_id

      t.uuid :root_node_id

      t.datetime :archived_at

      t.uuid :merged_into_subgraph_id
      t.check_constraint(
        "merged_into_subgraph_id IS NULL OR merged_into_subgraph_id <> id",
        name: "check_dag_subgraphs_no_self_merge"
      )

      t.datetime :merged_at

      t.references :attachable, type: :uuid, polymorphic: true, index: { unique: true }

      t.jsonb :metadata, null: false, default: {}

      t.bigint :next_anchored_seq, null: false, default: 0

      t.timestamps

      t.index %i[graph_id parent_subgraph_id], name: "index_dag_subgraphs_graph_parent"
      t.index %i[graph_id forked_from_node_id], name: "index_dag_subgraphs_graph_forked_from"
      t.index %i[graph_id merged_into_subgraph_id], name: "index_dag_subgraphs_graph_merged_into"
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

      t.uuid :subgraph_id, null: false
      t.index %i[graph_id subgraph_id], name: "index_dag_nodes_subgraph"

      t.string :node_type, null: false
      t.index %i[graph_id subgraph_id node_type created_at id],
              where: "compressed_at IS NULL",
              name: "index_dag_nodes_active_subgraph_type_created"

      t.string :state, null: false
      t.check_constraint(
        "state IN ('pending','awaiting_approval','running','finished','errored','rejected','skipped','stopped')",
        name: "check_dag_nodes_state_enum"
      )

      t.jsonb :metadata, null: false, default: {}

      t.uuid :turn_id, null: false, default: -> { "uuidv7()" }
      t.index %i[graph_id turn_id], name: "index_dag_nodes_turn"
      t.index %i[graph_id subgraph_id turn_id node_type id],
              where: "compressed_at IS NULL",
              name: "index_dag_nodes_active_subgraph_turn_type"

      t.uuid :version_set_id, null: false, default: -> { "uuidv7()" }
      t.index %i[graph_id version_set_id], name: "index_dag_nodes_version_set"

      t.string :idempotency_key
      t.index %i[graph_id turn_id node_type idempotency_key],
              unique: true,
              where: "compressed_at IS NULL AND idempotency_key IS NOT NULL",
              name: "index_dag_nodes_idempotency"

      t.references :body, type: :uuid, null: false,
                   foreign_key: { to_table: :dag_node_bodies },
                   index: { unique: true }

      t.uuid :retry_of_id
      t.index :retry_of_id, name: "index_dag_nodes_on_retry_of_id"

      t.uuid :compressed_by_id
      t.index :compressed_by_id, name: "index_dag_nodes_on_compressed_by_id"
      t.datetime :compressed_at
      t.check_constraint(
        "((compressed_at IS NULL) = (compressed_by_id IS NULL))",
        name: "check_dag_nodes_compressed_fields_consistent"
      )

      t.datetime :context_excluded_at
      t.check_constraint(
        "context_excluded_at IS NULL OR state IN ('finished','errored','rejected','skipped','stopped')",
        name: "check_dag_nodes_context_excluded_terminal"
      )

      t.datetime :deleted_at
      t.check_constraint(
        "deleted_at IS NULL OR state IN ('finished','errored','rejected','skipped','stopped')",
        name: "check_dag_nodes_deleted_terminal"
      )

      t.datetime :claimed_at
      t.string :claimed_by
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.index %i[graph_id lease_expires_at], where: "compressed_at IS NULL AND state = 'running'",
              name: "index_dag_nodes_running_lease"

      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    create_table :dag_node_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }

      t.uuid :node_id, null: false

      t.string :kind, null: false
      t.text :text
      t.jsonb :payload, null: false, default: {}

      t.datetime :created_at, null: false

      t.index %i[graph_id node_id id], name: "index_dag_node_events_graph_node_id_id"
      t.index %i[graph_id node_id kind id], name: "index_dag_node_events_graph_node_kind_id"
    end

    create_table :dag_node_visibility_patches, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :graph, null: false, type: :uuid,
                   foreign_key: { to_table: :dag_graphs, on_delete: :cascade }
      t.references :node, null: false, type: :uuid
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

      t.references :from_node, type: :uuid, null: false
      t.references :to_node, type: :uuid, null: false
      t.check_constraint "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"

      t.string :edge_type, null: false
      t.check_constraint(
        "edge_type IN ('sequence','dependency','branch')",
        name: "check_dag_edges_edge_type_enum"
      )

      t.jsonb :metadata, null: false, default: {}

      t.datetime :compressed_at
      t.timestamps
    end

    add_index :dag_subgraphs, %i[graph_id id], unique: true, name: "index_dag_subgraphs_graph_id_id_unique"
    add_index :dag_subgraphs, :graph_id,
              unique: true,
              where: "role = 'main'",
              name: "index_dag_subgraphs_main_per_graph"

    add_index :dag_nodes, %i[graph_id id], unique: true, name: "index_dag_nodes_graph_id_id_unique"

    add_foreign_key :dag_nodes, :dag_nodes,
                    column: %i[graph_id retry_of_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_nodes_retry_of_graph_scoped"

    add_foreign_key :dag_nodes, :dag_nodes,
                    column: %i[graph_id compressed_by_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_nodes_compressed_by_graph_scoped"

    add_foreign_key :dag_nodes, :dag_subgraphs,
                    column: %i[graph_id subgraph_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_nodes_subgraph_graph_scoped"

    add_foreign_key :dag_edges, :dag_nodes,
                    column: %i[graph_id from_node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_edges_from_node_graph_scoped",
                    on_delete: :cascade

    add_foreign_key :dag_edges, :dag_nodes,
                    column: %i[graph_id to_node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_edges_to_node_graph_scoped",
                    on_delete: :cascade

    add_foreign_key :dag_node_visibility_patches, :dag_nodes,
                    column: %i[graph_id node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_visibility_patches_node_graph_scoped",
                    on_delete: :cascade

    add_foreign_key :dag_node_events, :dag_nodes,
                    column: %i[graph_id node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_dag_node_events_node_graph_scoped",
                    on_delete: :cascade

    add_foreign_key :dag_subgraphs, :dag_subgraphs, column: :parent_subgraph_id, on_delete: :nullify
    add_foreign_key :dag_subgraphs, :dag_subgraphs, column: :merged_into_subgraph_id, on_delete: :nullify

    add_foreign_key :dag_subgraphs, :dag_nodes, column: :forked_from_node_id, on_delete: :nullify
    add_foreign_key :dag_subgraphs, :dag_nodes, column: :root_node_id, on_delete: :nullify
  end
end
