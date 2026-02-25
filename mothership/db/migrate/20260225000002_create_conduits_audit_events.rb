class CreateConduitsAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_audit_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account,   type: :uuid, null: false, foreign_key: true
      t.references :directive,  type: :uuid, null: true,
                   foreign_key: { to_table: :conduits_directives }
      t.references :actor,      type: :uuid, null: true,
                   foreign_key: { to_table: :users }
      t.string  :event_type, null: false
      t.string  :severity,   null: false, default: "info"
      t.jsonb   :payload,    null: false, default: {}
      t.jsonb   :context,    null: false, default: {}
      t.timestamps

      t.index [:event_type, :created_at]
      t.index [:directive_id, :created_at]
      t.index :created_at
    end
  end
end
