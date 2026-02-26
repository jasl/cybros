class CreateSessions < ActiveRecord::Migration[8.2]
  def change
    create_table :sessions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :identity, type: :uuid, foreign_key: true, null: false
      t.datetime :last_seen_at
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end

    add_index :sessions, %i[identity_id created_at]
  end
end

