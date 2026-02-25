class CreateConduitsTerritories < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_territories, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, type: :uuid, null: true, foreign_key: true, index: true

      t.string :name,   null: false
      t.string :status, null: false, index: true
      t.string :client_cert_fingerprint
      t.index :client_cert_fingerprint, unique: true, where: "client_cert_fingerprint IS NOT NULL",
              name: "idx_territories_cert_fingerprint"

      t.jsonb :labels, null: false, default: {}
      t.jsonb :capacity, null: false, default: {}
      t.string :nexus_version

      t.datetime :last_heartbeat_at

      t.timestamps
    end
  end
end
