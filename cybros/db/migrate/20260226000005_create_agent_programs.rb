class CreateAgentPrograms < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_programs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.text :description
      t.string :local_path
      t.jsonb :args, null: false, default: {}
      t.string :source_kind, null: false, default: "custom"
      t.string :bundled_agent_key
      t.uuid :forked_from_agent_program_id
      t.jsonb :manifest_snapshot, null: false, default: {}
      t.string :config_namespace, null: false
      t.jsonb :global_config, null: false, default: {}
      t.jsonb :global_config_schema, null: false, default: {}
      t.jsonb :conversation_config_schema, null: false, default: {}
      t.string :published_contract_fingerprint, null: false
      t.string :config_schema_fingerprint, null: false
      t.timestamps
    end

    add_index :agent_programs, :config_namespace, unique: true
    add_index :agent_programs,
      %i[source_kind bundled_agent_key],
      unique: true,
      where: "source_kind = 'bundled'",
      name: "idx_agent_programs_bundled_key"
    add_index :agent_programs, :forked_from_agent_program_id
    add_foreign_key :agent_programs, :agent_programs, column: :forked_from_agent_program_id
  end
end
