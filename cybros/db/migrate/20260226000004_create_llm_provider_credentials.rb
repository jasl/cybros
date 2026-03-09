class CreateLLMProviderCredentials < ActiveRecord::Migration[8.2]
  def change
    create_table :llm_provider_credentials, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :provider_key, null: false
      t.string :credential_type, null: false
      t.string :status, null: false, default: "active"
      t.integer :max_concurrent_requests, null: false, default: 4
      t.integer :requests_per_minute, null: false, default: 120
      t.integer :tokens_per_minute, null: false, default: 240000
      t.integer :burst_limit, null: false, default: 8
      t.jsonb :backoff_policy, null: false, default: { kind: "exponential", base_delay_ms: 500, max_delay_ms: 30000 }

      # api_key credential
      t.string :api_key

      # oauth_codex credential
      t.string :access_token
      t.string :refresh_token
      t.datetime :expires_at
      t.string :account_id

      t.timestamps
    end

    add_index :llm_provider_credentials,
      :provider_key,
      unique: true,
      where: "status = 'active'",
      name: "index_llm_provider_credentials_on_active_provider_key"
    add_index :llm_provider_credentials, %i[provider_key status]
  end
end
