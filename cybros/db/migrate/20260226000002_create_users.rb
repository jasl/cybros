class CreateUsers < ActiveRecord::Migration[8.2]
  def change
    create_table :users, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :identity, type: :uuid, foreign_key: true, null: false, index: { unique: true }
      t.integer :role, null: false, default: 0
      t.timestamps
    end
  end
end
