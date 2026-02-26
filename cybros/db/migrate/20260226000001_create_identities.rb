class CreateIdentities < ActiveRecord::Migration[8.2]
  def change
    create_table :identities, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :email, index: { unique: true }, limit: 255, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
  end
end
