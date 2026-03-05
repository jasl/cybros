class AddConversationTreeFields < ActiveRecord::Migration[8.2]
  def change
    change_table :conversations, bulk: true do |t|
      t.string :kind, index: true, null: false, default: "root"
      t.references :parent_conversation, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :nullify }, index: true
      t.references :root_conversation, type: :uuid, foreign_key: { to_table: :conversations, on_delete: :nullify }, index: true
      t.references :forked_from_node, type: :uuid, foreign_key: { to_table: :dag_nodes, on_delete: :nullify }
      t.text :summary
    end
  end
end
