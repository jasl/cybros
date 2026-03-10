class CreateLanePromptBufferEntries < ActiveRecord::Migration[8.2]
  def change
    create_table :lane_prompt_buffer_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :lane, null: false, type: :uuid, foreign_key: { to_table: :dag_lanes }
      t.string :buffer_name, null: false
      t.integer :seq, null: false
      t.string :kind, null: false, default: "note"
      t.integer :priority, null: false, default: 0
      t.text :content, null: false
      t.integer :estimated_tokens, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.string :written_by_type
      t.uuid :written_by_id

      t.timestamps
    end

    add_index :lane_prompt_buffer_entries, %i[lane_id buffer_name seq], unique: true, name: "index_lane_prompt_buffer_entries_on_lane_buffer_seq"
    add_index :lane_prompt_buffer_entries, %i[lane_id buffer_name priority seq], name: "index_lane_prompt_buffer_entries_on_lane_buffer_priority_seq"
    add_index :lane_prompt_buffer_entries, %i[written_by_type written_by_id], name: "index_lane_prompt_buffer_entries_on_writer"
    add_check_constraint :lane_prompt_buffer_entries, "btrim(buffer_name) <> ''", name: "check_lane_prompt_buffer_entries_buffer_name_present"
    add_check_constraint :lane_prompt_buffer_entries, "btrim(kind) <> ''", name: "check_lane_prompt_buffer_entries_kind_present"
    add_check_constraint :lane_prompt_buffer_entries, "btrim(content) <> ''", name: "check_lane_prompt_buffer_entries_content_present"
    add_check_constraint :lane_prompt_buffer_entries, "seq > 0", name: "check_lane_prompt_buffer_entries_seq_positive"
    add_check_constraint :lane_prompt_buffer_entries, "estimated_tokens >= 0", name: "check_lane_prompt_buffer_entries_estimated_tokens_nonnegative"
  end
end
