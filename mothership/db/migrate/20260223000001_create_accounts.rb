class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false

      t.timestamps
    end
  end
end
