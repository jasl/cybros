class AddProgrammableAgentColumnsToProgramsAndRuns < ActiveRecord::Migration[8.2]
  def change
    change_table :agent_programs, bulk: true do |t|
      t.jsonb :manifest_snapshot, null: false, default: {}
      t.string :config_namespace, null: false
      t.jsonb :global_config, null: false, default: {}
      t.jsonb :global_config_schema, null: false, default: {}
      t.jsonb :conversation_config_schema, null: false, default: {}
      t.string :published_contract_fingerprint, null: false
      t.string :config_schema_fingerprint, null: false
    end

    add_index :agent_programs, :config_namespace, unique: true

    change_table :conversation_runs, bulk: true do |t|
      t.integer :snapshot_version
      t.references :initiated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.string :effective_permission_mode
      t.references :agent_program, type: :uuid, foreign_key: true, index: true
      t.string :contract_fingerprint
      t.references :agent_deployment, type: :uuid, foreign_key: true, index: true
      t.string :deployment_fingerprint
      t.datetime :deployment_activated_at
      t.references :provider_credential, type: :uuid, foreign_key: { to_table: :llm_provider_credentials }, index: true
      t.references :execution_target, type: :uuid, foreign_key: true, index: true
      t.string :selected_model_ref
      t.jsonb :effective_public_settings, null: false, default: {}
      t.jsonb :effective_agent_config, null: false, default: {}
      t.string :agent_config_schema_fingerprint
      t.jsonb :effective_policy, null: false, default: {}
      t.jsonb :runtime_governors, null: false, default: {}
      t.jsonb :snapshot, null: false, default: {}
    end
  end
end
