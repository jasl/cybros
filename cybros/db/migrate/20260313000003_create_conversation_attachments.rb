class CreateConversationAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :conversation_attachments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, null: false, type: :uuid, foreign_key: true
      t.uuid :source_message_node_id, null: false
      t.integer :position, null: false
      t.string :sha256_digest
      t.timestamps
    end

    add_index :conversation_attachments, [:conversation_id, :source_message_node_id, :position], unique: true, name: "idx_conversation_attachments_message_position"
    add_index :conversation_attachments, :source_message_node_id
  end
end
