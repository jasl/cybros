class CreateConversationKVEntries < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_kv_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, null: false, type: :uuid, foreign_key: true
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.string :written_by_type
      t.uuid :written_by_id

      t.timestamps
    end

    add_index :conversation_kv_entries, %i[conversation_id key], unique: true
    add_index :conversation_kv_entries, %i[written_by_type written_by_id]
    add_check_constraint :conversation_kv_entries, "btrim(key) <> ''", name: "check_conversation_kv_entries_key_present"
  end
end
