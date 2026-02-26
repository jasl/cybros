class CreateConversationRuns < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_runs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.uuid :dag_node_id, null: false

      t.string :state, null: false, default: "queued"
      t.datetime :queued_at, null: false
      t.datetime :started_at
      t.datetime :finished_at

      t.jsonb :debug, null: false, default: {}
      t.jsonb :error, null: false, default: {}

      t.timestamps
    end

    add_index :conversation_runs, :dag_node_id
    add_index :conversation_runs, %i[conversation_id state]
  end
end
