class CreateLaneKVEntries < ActiveRecord::Migration[8.2]
  def change
    create_table :lane_kv_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :lane, null: false, type: :uuid, foreign_key: { to_table: :dag_lanes }
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.string :written_by_type
      t.uuid :written_by_id

      t.timestamps
    end

    add_index :lane_kv_entries, %i[lane_id key], unique: true
    add_index :lane_kv_entries, %i[written_by_type written_by_id]
    add_check_constraint :lane_kv_entries, "btrim(key) <> ''", name: "check_lane_kv_entries_key_present"
  end
end
