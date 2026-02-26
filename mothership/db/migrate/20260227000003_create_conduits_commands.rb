class CreateConduitsCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_commands, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :territory, null: false, foreign_key: { to_table: :conduits_territories }, type: :uuid
      t.references :bridge_entity, foreign_key: { to_table: :conduits_bridge_entities }, type: :uuid
      t.references :requested_by_user, foreign_key: { to_table: :users }, type: :uuid

      t.string :capability, null: false
      t.jsonb :params, null: false, default: {}
      t.string :state, null: false, default: "queued"
      t.jsonb :result, null: false, default: {}
      t.string :error_message
      t.integer :timeout_seconds, null: false, default: 30

      t.datetime :dispatched_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :conduits_commands, [:territory_id, :state], name: "idx_commands_territory_state"
    add_index :conduits_commands, :state
  end
end
