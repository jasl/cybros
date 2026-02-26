class AddDeviceFieldsToConduitsTerritories < ActiveRecord::Migration[8.1]
  def change
    add_column :conduits_territories, :kind, :string, null: false, default: "server"
    add_column :conduits_territories, :platform, :string
    add_column :conduits_territories, :display_name, :string
    add_column :conduits_territories, :location, :string
    add_column :conduits_territories, :tags, :jsonb, null: false, default: []
    add_column :conduits_territories, :capabilities, :jsonb, null: false, default: []
    add_column :conduits_territories, :websocket_connected_at, :datetime
    add_column :conduits_territories, :push_token, :string
    add_column :conduits_territories, :push_platform, :string

    add_index :conduits_territories, :kind
    add_index :conduits_territories, :capabilities, using: :gin
    add_index :conduits_territories, :tags, using: :gin
  end
end
