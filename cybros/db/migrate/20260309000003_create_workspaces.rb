class CreateWorkspaces < ActiveRecord::Migration[8.2]
  def change
    create_table :workspaces, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :execution_location, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :root_path, null: false
      t.string :workspace_type, null: false
      t.string :status, null: false, default: "active"
      t.text :capability_tags, array: true, null: false, default: []
      t.text :tags, array: true, null: false, default: []
      t.timestamps
    end

    add_index :workspaces, %i[execution_location_id root_path], unique: true
  end
end
