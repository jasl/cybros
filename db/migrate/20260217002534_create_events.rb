class CreateEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: false

      t.references :subject, type: :uuid, polymorphic: true, null: false

      t.string :event_type, null: false
      t.jsonb :particulars, null: false, default: {}

      t.datetime :created_at, null: false

      t.index %i[conversation_id created_at], name: "index_events_on_conversation_id_and_created_at"
      t.index %i[subject_type subject_id created_at], name: "index_events_on_subject_and_created_at"
    end
  end
end
