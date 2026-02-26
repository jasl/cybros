class CreateConduitsBridgeEntities < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_bridge_entities, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :territory, null: false, foreign_key: { to_table: :conduits_territories }, type: :uuid
      t.references :account, null: false, foreign_key: true, type: :uuid

      t.string :entity_ref, null: false
      t.string :entity_type, null: false
      t.string :display_name
      t.jsonb :capabilities, null: false, default: []
      t.string :location
      t.jsonb :state, null: false, default: {}
      t.boolean :available, null: false, default: true
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :conduits_bridge_entities, [:territory_id, :entity_ref], unique: true,
              name: "idx_bridge_entities_territory_ref"
    add_index :conduits_bridge_entities, :capabilities, using: :gin
    add_index :conduits_bridge_entities, :entity_type
  end
end
