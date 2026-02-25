class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, type: :uuid, null: true, foreign_key: true, index: true

      t.string :name

      t.timestamps
    end
  end
end
