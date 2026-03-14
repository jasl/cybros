class CreateAgentsAndRecognizedDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :agents, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :legacy_agent_program_id
      t.uuid :legacy_execution_target_id
      t.jsonb :args, default: {}, null: false
      t.string :bundled_agent_key
      t.string :config_namespace, null: false
      t.string :config_schema_fingerprint, null: false
      t.jsonb :conversation_config_schema, default: {}, null: false
      t.text :description
      t.jsonb :global_config, default: {}, null: false
      t.jsonb :global_config_schema, default: {}, null: false
      t.string :local_path
      t.jsonb :manifest_snapshot, default: {}, null: false
      t.integer :max_concurrent_tasks
      t.integer :max_queued_tasks
      t.integer :default_timeout_s
      t.integer :cpu_limit_millicores
      t.integer :memory_limit_mb
      t.string :name, null: false
      t.string :published_contract_fingerprint, null: false
      t.string :source_kind, null: false, default: "custom"
      t.timestamps
    end

    add_index :agents, :config_namespace, unique: true
    add_index :agents, :legacy_agent_program_id, unique: true
    add_index :agents, [:source_kind, :bundled_agent_key], unique: true, where: "source_kind = 'bundled'", name: "idx_agents_bundled_key"
    add_foreign_key :agents, :agent_programs, column: :legacy_agent_program_id
    add_foreign_key :agents, :execution_targets, column: :legacy_execution_target_id

    create_table :recognized_deployments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :agent_id, null: false
      t.uuid :legacy_agent_deployment_id
      t.string :identity_digest, null: false
      t.string :recognized_deployment_key, null: false
      t.string :contract_fingerprint
      t.string :deployment_fingerprint, null: false
      t.string :protocol_version, null: false
      t.jsonb :supported_methods, default: [], null: false
      t.string :agent_sdk_version
      t.string :agent_capabilities_version
      t.string :capability_snapshot_digest
      t.jsonb :capability_snapshot, default: {}, null: false
      t.boolean :supports_upload, null: false, default: false
      t.string :hostname
      t.string :container_id
      t.string :git_sha
      t.string :build_id
      t.string :image_digest
      t.datetime :booted_at
      t.datetime :retired_at
      t.timestamps
    end

    add_index :recognized_deployments, :recognized_deployment_key, unique: true
    add_index :recognized_deployments, [:agent_id, :identity_digest], unique: true, name: "idx_recognized_deployments_identity"
    add_foreign_key :recognized_deployments, :agents
    add_foreign_key :recognized_deployments, :agent_deployments, column: :legacy_agent_deployment_id

    add_reference :conversations, :agent, type: :uuid, foreign_key: true
    add_reference :automations, :agent, type: :uuid, foreign_key: true

    add_reference :run_drafts, :agent, type: :uuid, foreign_key: true
    add_reference :run_drafts, :recognized_deployment, type: :uuid, foreign_key: true
    add_column :run_drafts, :recognized_deployment_key, :string
    add_index :run_drafts, :recognized_deployment_key

    add_reference :conversation_runs, :agent, type: :uuid, foreign_key: true
    add_reference :conversation_runs, :recognized_deployment, type: :uuid, foreign_key: true
    add_column :conversation_runs, :recognized_deployment_key, :string
    add_index :conversation_runs, :recognized_deployment_key
  end
end
