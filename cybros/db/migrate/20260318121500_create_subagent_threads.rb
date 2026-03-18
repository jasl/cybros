class CreateSubagentThreads < ActiveRecord::Migration[8.2]
  def change
    add_index :dag_turns, %i[graph_id id], unique: true, name: "index_dag_turns_graph_id_id_unique"

    create_table :subagent_threads, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :owner_conversation, null: false, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :restrict }
      t.references :owner_graph, null: false, type: :uuid, foreign_key: { to_table: :dag_graphs, on_delete: :restrict }
      t.references :owner_turn, null: false, type: :uuid, foreign_key: { to_table: :dag_turns, on_delete: :restrict }
      t.references :owner_node, null: false, type: :uuid, foreign_key: { to_table: :dag_nodes, on_delete: :restrict }
      t.references :child_conversation, null: false, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :restrict }, index: { unique: true }
      t.references :child_graph, null: false, type: :uuid, foreign_key: { to_table: :dag_graphs, on_delete: :restrict }, index: { unique: true }

      t.string :status, null: false, default: "active"
      t.string :child_status, null: false, default: "pending"
      t.integer :depth, null: false, default: 1
      t.string :requested_name, null: false
      t.string :title, null: false
      t.string :agent_profile, null: false
      t.integer :context_turns, null: false
      t.string :diagnostic_level, null: false, default: "standard"

      t.string :terminal_origin
      t.string :terminal_reason
      t.datetime :terminal_at
      t.string :freeze_reason
      t.datetime :frozen_at
      t.datetime :owner_finalized_at
      t.datetime :closed_at
      t.datetime :owner_notified_at

      t.jsonb :last_snapshot, null: false, default: {}
      t.jsonb :final_snapshot, null: false, default: {}
      t.jsonb :result_summary, null: false, default: {}
      t.jsonb :artifacts_summary, null: false, default: {}
      t.jsonb :last_error_snapshot, null: false, default: {}
      t.string :integrity_state
      t.jsonb :integrity_error, null: false, default: {}

      t.timestamps
    end

    add_index :subagent_threads, %i[owner_turn_id status], name: "idx_subagent_threads_owner_turn_status"
    add_index :subagent_threads, %i[owner_conversation_id status], name: "idx_subagent_threads_owner_conversation_status"
    add_index :subagent_threads, %i[owner_node_id status], name: "idx_subagent_threads_owner_node_status"

    add_foreign_key :subagent_threads,
                    :dag_turns,
                    column: %i[owner_graph_id owner_turn_id],
                    primary_key: %i[graph_id id],
                    name: "fk_subagent_threads_owner_turn_graph_scoped",
                    on_delete: :restrict
    add_foreign_key :subagent_threads,
                    :dag_nodes,
                    column: %i[owner_graph_id owner_node_id],
                    primary_key: %i[graph_id id],
                    name: "fk_subagent_threads_owner_node_graph_scoped",
                    on_delete: :restrict

    add_check_constraint :subagent_threads, "status IN ('active', 'frozen', 'closed', 'killed', 'missing')", name: "check_subagent_threads_status"
    add_check_constraint :subagent_threads, "child_status IN ('pending', 'running', 'awaiting_approval', 'idle', 'failed', 'stopped', 'missing')", name: "check_subagent_threads_child_status"
    add_check_constraint :subagent_threads, "depth > 0", name: "check_subagent_threads_depth_positive"
    add_check_constraint :subagent_threads, "context_turns > 0", name: "check_subagent_threads_context_turns_positive"
    add_check_constraint :subagent_threads, "btrim(requested_name) <> ''", name: "check_subagent_threads_requested_name_present"
    add_check_constraint :subagent_threads, "btrim(title) <> ''", name: "check_subagent_threads_title_present"
    add_check_constraint :subagent_threads, "btrim(agent_profile) <> ''", name: "check_subagent_threads_agent_profile_present"
    add_check_constraint :subagent_threads, "diagnostic_level IN ('standard', 'debug')", name: "check_subagent_threads_diagnostic_level"
    add_check_constraint :subagent_threads, "terminal_origin IS NULL OR terminal_origin IN ('owner_action', 'child_runtime', 'system_reconcile', 'integrity_guard')", name: "check_subagent_threads_terminal_origin"
  end
end
