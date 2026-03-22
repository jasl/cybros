class CreateConversationAttachmentPreparations < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_attachment_preparations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation_attachment, null: false, type: :uuid, foreign_key: true
      t.references :run_draft, null: false, type: :uuid, foreign_key: true
      t.references :recognized_deployment, null: false, type: :uuid, foreign_key: true
      t.string :transfer_mode, null: false
      t.string :status, null: false
      t.jsonb :prepared_ref, null: false, default: {}
      t.datetime :prepared_at, null: false

      t.timestamps
    end

    add_index :conversation_attachment_preparations,
              [:conversation_attachment_id, :run_draft_id],
              unique: true,
              name: "idx_attachment_preparations_attachment_run_draft"
  end
end
