class CreateConversations < ActiveRecord::Migration[8.2]
  def change
    create_table :conversations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :title
      t.text :summary
      t.jsonb :metadata, null: false, default: {}

      t.string :kind, index: true, null: false, default: "root"
      t.references :parent_conversation, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :nullify }, index: true
      t.references :root_conversation, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :nullify }, index: true
      t.references :forked_from_node, type: :uuid, foreign_key: { to_table: :dag_nodes, on_delete: :nullify }

      t.timestamps
    end
  end
end
