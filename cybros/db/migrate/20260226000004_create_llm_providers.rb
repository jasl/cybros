class CreateLLMProviders < ActiveRecord::Migration[8.2]
  def change
    create_table :llm_providers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :base_url, null: false
      t.string :api_key
      t.string :api_format, null: false, default: "openai"
      t.jsonb :headers, null: false, default: {}
      t.string :model_allowlist, null: false, default: [], array: true
      t.integer :priority, index: true, null: false, default: 0
      t.timestamps
    end
  end
end
