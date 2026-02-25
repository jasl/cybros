class CreateConduitsFacilities < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_facilities, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account,   type: :uuid, null: true,  foreign_key: true, index: true
      t.references :owner,     type: :uuid, null: false,
                   foreign_key: { to_table: :users }, index: true
      t.references :territory, type: :uuid, null: false,
                   foreign_key: { to_table: :conduits_territories }, index: true

      # Circular FK with conduits_directives: declare as plain column here.
      # No DB-level FK — SQLite's add_foreign_key rebuilds the table and loses
      # column type annotations. Enforced at the application layer (model belongs_to).
      t.column :locked_by_directive_id, :uuid, null: true, index: true

      t.string  :kind,             null: false
      t.string  :root_handle
      t.string  :repo_url
      t.jsonb   :retention_policy, null: false, index: true
      t.integer :size_bytes,       null: false, default: 0

      t.timestamps
    end
  end
end
