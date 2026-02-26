class CreateConversationRuns < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_runs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.uuid :dag_node_id, index: true, null: false

      t.string :state, null: false, default: "queued"
      t.index %i[conversation_id state]

      t.datetime :queued_at, null: false
      t.datetime :started_at
      t.datetime :finished_at

      t.jsonb :debug, null: false, default: {}
      t.jsonb :error, null: false, default: {}

      t.timestamps
    end
  end
end
