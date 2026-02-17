class CreateDAGWorkflowEngine < ActiveRecord::Migration[8.2]
  def change
    create_table :dag_nodes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :node_type, null: false
      t.string :state, null: false
      t.jsonb :metadata, null: false, default: {}
      t.text :content

      t.references :retry_of, type: :uuid, foreign_key: { to_table: :dag_nodes }

      t.references :compressed_by, type: :uuid, foreign_key: { to_table: :dag_nodes }
      t.datetime :compressed_at

      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    create_table :dag_edges, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :from_node, type: :uuid, foreign_key: { to_table: :dag_nodes }, null: false
      t.references :to_node, type: :uuid, foreign_key: { to_table: :dag_nodes }, null: false
      t.check_constraint "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"

      t.string :edge_type, null: false
      t.jsonb :metadata, null: false, default: {}

      t.datetime :compressed_at
      t.timestamps
    end
  end
end
