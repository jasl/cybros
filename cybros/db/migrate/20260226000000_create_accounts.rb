class CreateAccounts < ActiveRecord::Migration[8.2]
  def change
    create_table :accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end
  end
end

