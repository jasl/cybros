class CreateTurnInternalTasks < ActiveRecord::Migration[8.2]
  def change
    create_table :turn_internal_tasks, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, null: false, type: :uuid, foreign_key: true
      t.references :graph, null: false, type: :uuid, foreign_key: { to_table: :dag_graphs }
      t.references :lane, null: false, type: :uuid, foreign_key: { to_table: :dag_lanes }
      t.uuid :turn_id, null: false
      t.uuid :source_node_id, null: false
      t.string :source_hook_name, null: false
      t.string :source_fingerprint, null: false
      t.string :logical_tool_name, null: false
      t.jsonb :input, null: false, default: {}
      t.jsonb :authored_metadata, null: false, default: {}
      t.string :tool_surface_id
      t.string :capability_registry_snapshot_id
      t.string :execution_mode, null: false, default: "serial"
      t.integer :queue_position, null: false
      t.string :status, null: false, default: "queued"
      t.references :materialized_task_node, type: :uuid, foreign_key: { to_table: :dag_nodes }
      t.references :superseded_by, type: :uuid, foreign_key: { to_table: :turn_internal_tasks }
      t.string :canceled_reason

      t.timestamps
    end

    add_index :turn_internal_tasks, %i[turn_id source_fingerprint], unique: true, name: "idx_turn_internal_tasks_turn_source_fingerprint"
    add_index :turn_internal_tasks, %i[turn_id queue_position], unique: true, name: "idx_turn_internal_tasks_turn_queue_position"
    add_index :turn_internal_tasks, %i[graph_id status queue_position], name: "idx_turn_internal_tasks_graph_status_position"

    add_foreign_key :turn_internal_tasks,
                    :dag_lanes,
                    column: %i[graph_id lane_id],
                    primary_key: %i[graph_id id],
                    name: "fk_turn_internal_tasks_lane_graph_scoped",
                    on_delete: :cascade
    add_foreign_key :turn_internal_tasks,
                    :dag_turns,
                    column: %i[graph_id lane_id turn_id],
                    primary_key: %i[graph_id lane_id id],
                    name: "fk_turn_internal_tasks_turn_graph_scoped",
                    on_delete: :cascade
    add_foreign_key :turn_internal_tasks,
                    :dag_nodes,
                    column: %i[graph_id source_node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_turn_internal_tasks_source_node_graph_scoped",
                    on_delete: :cascade
    add_check_constraint :turn_internal_tasks, "btrim(source_hook_name) <> ''", name: "check_turn_internal_tasks_source_hook_name_present"
    add_check_constraint :turn_internal_tasks, "btrim(source_fingerprint) <> ''", name: "check_turn_internal_tasks_source_fingerprint_present"
    add_check_constraint :turn_internal_tasks, "btrim(logical_tool_name) <> ''", name: "check_turn_internal_tasks_logical_tool_name_present"
    add_check_constraint :turn_internal_tasks, "queue_position > 0", name: "check_turn_internal_tasks_queue_position_positive"
    add_check_constraint :turn_internal_tasks, "status IN ('queued', 'materializing', 'materialized', 'running', 'finished', 'canceled', 'superseded', 'failed_materialization')", name: "check_turn_internal_tasks_status"
    add_check_constraint :turn_internal_tasks, "execution_mode IN ('serial', 'parallel_safe')", name: "check_turn_internal_tasks_execution_mode"
  end
end
