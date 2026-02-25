class CreateConduitsEnrollmentTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_enrollment_tokens, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true, index: true
      t.references :created_by_user, type: :uuid, null: false,
                   foreign_key: { to_table: :users }, index: true

      t.string :token_digest, null: false, index: { unique: true }
      t.jsonb :labels, null: false, default: {}

      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :revoked_at

      t.timestamps
    end
  end
end
