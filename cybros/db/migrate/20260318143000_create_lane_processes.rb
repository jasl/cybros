class CreateLaneProcesses < ActiveRecord::Migration[8.2]
  def change
    create_table :lane_processes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :lane, null: false, type: :uuid, foreign_key: { to_table: :dag_lanes, on_delete: :cascade }
      t.references :owner_turn, null: true, type: :uuid, foreign_key: { to_table: :dag_turns, on_delete: :nullify }
      t.string :started_by_type, null: false
      t.string :status, null: false
      t.string :title
      t.text :command
      t.text :cwd
      t.bigint :pid
      t.bigint :pgid
      t.text :log_path
      t.jsonb :port_hints, null: false, default: []
      t.integer :exit_code
      t.datetime :started_at
      t.datetime :last_seen_at
      t.datetime :ended_at
      t.jsonb :summary_json, null: false, default: {}
      t.timestamps
    end

    add_index :lane_processes, [:conversation_id, :status], name: "index_lane_processes_on_conversation_and_status"
    add_index :lane_processes, [:lane_id, :status], name: "index_lane_processes_on_lane_and_status"
  end
end
