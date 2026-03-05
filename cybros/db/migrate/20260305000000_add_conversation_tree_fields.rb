class AddConversationTreeFields < ActiveRecord::Migration[8.2]
  def change
    change_table :conversations, bulk: true do |t|
      t.string :kind, null: false, default: "root"
      t.uuid :parent_conversation_id
      t.uuid :root_conversation_id
      t.uuid :forked_from_node_id
      t.text :summary
    end

    add_index :conversations, :kind
    add_index :conversations, :parent_conversation_id
    add_index :conversations, :root_conversation_id
    add_index :conversations, :forked_from_node_id

    add_foreign_key :conversations, :conversations, column: :parent_conversation_id, on_delete: :nullify
    add_foreign_key :conversations, :conversations, column: :root_conversation_id, on_delete: :nullify
  end
end
