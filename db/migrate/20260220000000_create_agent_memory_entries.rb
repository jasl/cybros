# frozen_string_literal: true

class CreateAgentMemoryEntries < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_memory_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: true

      t.text :content, null: false
      t.jsonb :metadata, null: false, default: {}, index: { using: :gin }
      t.vector :embedding, limit: 1536, null: false

      t.timestamps
    end

    execute <<~SQL
      CREATE INDEX index_agent_memory_entries_on_embedding
      ON agent_memory_entries
      USING hnsw (embedding vector_cosine_ops);
    SQL
  end
end
