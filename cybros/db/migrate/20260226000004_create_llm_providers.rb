class CreateLLMProviders < ActiveRecord::Migration[8.2]
  def change
    create_table :llm_providers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :provider_key, null: false, index: { unique: true }
      t.string :credential_type, null: false

      # api_key credential
      t.string :api_key

      # oauth_codex credential
      t.string :access_token
      t.string :refresh_token
      t.datetime :expires_at
      t.string :account_id

      t.timestamps
    end
  end
end
