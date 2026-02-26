class CreateIdentities < ActiveRecord::Migration[8.2]
  def change
    create_table :identities, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end

    add_index :identities, "lower(email)", unique: true, name: "index_identities_on_lower_email_unique"
  end
end

