class CreateConversations < ActiveRecord::Migration[8.2]
  def change
    create_table :conversations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :title
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    change_table :dag_nodes do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: false
      t.index %i[conversation_id state node_type], name: "index_dag_nodes_lookup"
      t.index %i[conversation_id created_at], name: "index_dag_nodes_created_at"
      t.index %i[conversation_id compressed_at], name: "index_dag_nodes_compressed_at"
      t.index %i[conversation_id retry_of_id], name: "index_dag_nodes_retry_of"
    end

    change_table :dag_edges do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: false
      t.index %i[conversation_id from_node_id to_node_id edge_type], unique: true,
              name: "index_dag_edges_uniqueness"
      t.index %i[conversation_id from_node_id], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_from"
      t.index %i[conversation_id to_node_id], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_to"
      t.index %i[conversation_id edge_type], where: "compressed_at IS NULL",
              name: "index_dag_edges_active_type"
    end
  end
end
