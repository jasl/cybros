class CreateDAGWorkflowEngine < ActiveRecord::Migration[8.2]
  def change
    create_table :conversations, id: :string, limit: 25 do |t|
      t.string :title
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :dag_nodes, id: :string, limit: 25 do |t|
      t.string :conversation_id, limit: 25, null: false
      t.string :node_type, null: false
      t.string :state, null: false
      t.text :content
      t.jsonb :metadata, null: false, default: {}
      t.string :retry_of_id, limit: 25
      t.datetime :compressed_at
      t.string :compressed_by_id, limit: 25
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_foreign_key :dag_nodes, :conversations

    add_check_constraint :dag_nodes,
      "node_type IN ('user_message','agent_message','task','summary')",
      name: "check_dag_nodes_node_type"
    add_check_constraint :dag_nodes,
      "state IN ('pending','running','finished','errored','rejected','skipped','cancelled')",
      name: "check_dag_nodes_state"

    add_index :dag_nodes, [:conversation_id, :state, :node_type], name: "index_dag_nodes_lookup"
    add_index :dag_nodes, [:conversation_id, :created_at], name: "index_dag_nodes_created_at"
    add_index :dag_nodes, [:conversation_id, :compressed_at], name: "index_dag_nodes_compressed_at"
    add_index :dag_nodes, [:conversation_id, :retry_of_id], name: "index_dag_nodes_retry_of"

    create_table :dag_edges, id: :string, limit: 25 do |t|
      t.string :conversation_id, limit: 25, null: false
      t.string :from_node_id, limit: 25, null: false
      t.string :to_node_id, limit: 25, null: false
      t.string :edge_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :compressed_at
      t.timestamps
    end

    add_foreign_key :dag_edges, :conversations
    add_foreign_key :dag_edges, :dag_nodes, column: :from_node_id
    add_foreign_key :dag_edges, :dag_nodes, column: :to_node_id

    add_check_constraint :dag_edges, "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"
    add_check_constraint :dag_edges,
      "edge_type IN ('sequence','dependency','branch')",
      name: "check_dag_edges_edge_type"

    add_index :dag_edges,
      [:conversation_id, :from_node_id, :to_node_id, :edge_type],
      unique: true,
      name: "index_dag_edges_uniqueness"
    add_index :dag_edges,
      [:conversation_id, :from_node_id],
      where: "compressed_at IS NULL",
      name: "index_dag_edges_active_from"
    add_index :dag_edges,
      [:conversation_id, :to_node_id],
      where: "compressed_at IS NULL",
      name: "index_dag_edges_active_to"
    add_index :dag_edges,
      [:conversation_id, :edge_type],
      where: "compressed_at IS NULL",
      name: "index_dag_edges_active_type"

    create_table :events, id: :string, limit: 25 do |t|
      t.string :conversation_id, limit: 25, null: false
      t.string :event_type, null: false
      t.string :subject_type
      t.string :subject_id, limit: 25
      t.jsonb :particulars, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_foreign_key :events, :conversations
    add_index :events, [:conversation_id, :created_at], name: "index_events_on_conversation_id_and_created_at"
    add_index :events, [:subject_type, :subject_id, :created_at], name: "index_events_on_subject_and_created_at"
  end
end
