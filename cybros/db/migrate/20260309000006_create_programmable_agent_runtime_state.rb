class CreateProgrammableAgentRuntimeState < ActiveRecord::Migration[8.2]
  def change
    change_table :conversations, bulk: true do |t|
      t.references :agent_program, null: false, type: :uuid, foreign_key: true, index: true
      t.references :default_execution_target, type: :uuid, foreign_key: { to_table: :execution_targets }, index: true
      t.string :permission_mode, null: false, default: "default"
      t.jsonb :public_settings, null: false, default: {}
      t.jsonb :agent_config, null: false, default: {}
      t.string :agent_config_schema_fingerprint
    end

    create_table :agent_deployments, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :agent_program, null: false, type: :uuid, foreign_key: true
      t.string :transport_kind, null: false
      t.string :endpoint_url
      t.jsonb :transport_config, null: false, default: {}
      t.string :deployment_bearer_secret_ref, null: false
      t.string :contract_fingerprint, null: false
      t.string :deployment_fingerprint, null: false
      t.string :status, null: false, default: "inactive"
      t.string :health_status, null: false, default: "unknown"
      t.string :protocol_version, null: false
      t.string :agent_sdk_version
      t.text :supported_methods, array: true, null: false, default: []
      t.jsonb :manifest_snapshot, null: false, default: {}
      t.jsonb :schema_snapshot, null: false, default: {}
      t.jsonb :capability_snapshot, null: false, default: {}
      t.jsonb :inspection_details, null: false, default: {}
      t.datetime :last_inspected_at
      t.datetime :last_health_checked_at
      t.datetime :activated_at
      t.datetime :deactivated_at
      t.timestamps
    end

    add_index :agent_deployments,
      :agent_program_id,
      unique: true,
      where: "status = 'active'",
      name: "idx_agent_deploy_active_program"
    add_index :agent_deployments,
      %i[id agent_program_id],
      unique: true,
      name: "idx_agent_deployments_id_program"

    change_table :conversation_runs, bulk: true do |t|
      t.integer :snapshot_version, null: false
      t.references :initiated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.string :effective_permission_mode, null: false
      t.references :agent_program, null: false, type: :uuid, foreign_key: true, index: true
      t.string :contract_fingerprint, null: false
      t.references :agent_deployment, null: false, type: :uuid, foreign_key: true, index: true
      t.string :deployment_fingerprint, null: false
      t.datetime :deployment_activated_at, null: false
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

    add_index :conversation_runs,
      %i[agent_deployment_id agent_program_id],
      name: "idx_conversation_runs_deploy_program"
    add_foreign_key :conversation_runs,
      :agent_deployments,
      column: %i[agent_deployment_id agent_program_id],
      primary_key: %i[id agent_program_id],
      name: "fk_conversation_runs_deploy_program"

    create_table :run_drafts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, null: false, type: :uuid, foreign_key: true
      t.references :initiated_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "open"
      t.string :permission_mode, null: false
      t.string :agent_config_schema_fingerprint, null: false
      t.jsonb :trigger_snapshot, null: false, default: {}
      t.references :agent_program, null: false, type: :uuid, foreign_key: true
      t.string :contract_fingerprint, null: false
      t.references :agent_deployment, null: false, type: :uuid, foreign_key: true
      t.string :deployment_fingerprint, null: false
      t.datetime :deployment_activated_at, null: false
      t.references :provider_credential, type: :uuid, foreign_key: { to_table: :llm_provider_credentials }
      t.references :proposed_execution_target, type: :uuid, foreign_key: { to_table: :execution_targets }
      t.string :selected_model_ref
      t.jsonb :runtime_governors, null: false, default: {}
      t.string :prepare_invocation_id
      t.jsonb :prepared_plan, null: false, default: {}
      t.jsonb :staged_public_settings_patch, null: false, default: {}
      t.jsonb :staged_agent_config_patch, null: false, default: {}
      t.jsonb :staged_kv_ops, null: false, default: []
      t.jsonb :approval_state, null: false, default: {}
      t.datetime :expires_at, null: false
      t.references :materialized_conversation_run, type: :uuid, foreign_key: { to_table: :conversation_runs }
      t.timestamps
    end

    add_index :run_drafts, %i[conversation_id status], name: "idx_run_drafts_conversation_status"
    add_index :run_drafts, %i[agent_deployment_id agent_program_id], name: "idx_run_drafts_deploy_program"
    add_foreign_key :run_drafts,
      :agent_deployments,
      column: %i[agent_deployment_id agent_program_id],
      primary_key: %i[id agent_program_id],
      name: "fk_run_drafts_deployment_program"

    create_table :agent_rpc_invocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :agent_deployment, null: false, type: :uuid, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: true
      t.string :scope_type, null: false
      t.string :scope_id, null: false
      t.string :method, null: false
      t.string :invocation_id, null: false
      t.string :binding_fingerprint, null: false
      t.datetime :deployment_activated_at, null: false
      t.string :request_payload_hash, null: false
      t.string :status, null: false
      t.jsonb :result_snapshot, null: false, default: {}
      t.jsonb :error_snapshot, null: false, default: {}
      t.uuid :last_session_id
      t.timestamps
    end

    add_index :agent_rpc_invocations,
      %i[agent_deployment_id binding_fingerprint deployment_activated_at scope_type scope_id method invocation_id],
      unique: true,
      name: "idx_agent_rpc_invocations_replay"
    add_index :agent_rpc_invocations,
      %i[id agent_deployment_id],
      unique: true,
      name: "idx_agent_rpc_invocations_id_deploy"

    create_table :agent_rpc_sessions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :agent_deployment, null: false, type: :uuid, foreign_key: true
      t.references :agent_program, null: false, type: :uuid, foreign_key: true
      t.references :agent_rpc_invocation, type: :uuid, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: true
      t.string :scope_type, null: false
      t.string :scope_id, null: false
      t.string :deployment_fingerprint, null: false
      t.datetime :deployment_activated_at, null: false
      t.string :session_token_digest, null: false
      t.text :allowed_methods, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.string :status, null: false
      t.timestamps
    end

    add_index :agent_rpc_sessions, :session_token_digest, unique: true, name: "idx_agent_rpc_sessions_token"
    add_index :agent_rpc_sessions,
      %i[agent_rpc_invocation_id agent_deployment_id],
      name: "idx_agent_rpc_sessions_invocation_deploy"

    add_foreign_key :agent_rpc_invocations,
      :agent_rpc_sessions,
      column: :last_session_id
    add_foreign_key :agent_rpc_sessions,
      :agent_deployments,
      column: %i[agent_deployment_id agent_program_id],
      primary_key: %i[id agent_program_id],
      name: "fk_agent_rpc_sessions_deploy_program"
    add_foreign_key :agent_rpc_sessions,
      :agent_rpc_invocations,
      column: %i[agent_rpc_invocation_id agent_deployment_id],
      primary_key: %i[id agent_deployment_id],
      name: "fk_agent_rpc_sessions_invocation_deploy"

    create_table :agent_rpc_operation_receipts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :agent_rpc_invocation, null: false, type: :uuid, foreign_key: true
      t.string :operation_id, null: false
      t.string :method, null: false
      t.string :payload_hash, null: false
      t.string :status, null: false
      t.jsonb :response_snapshot, null: false, default: {}
      t.timestamps
    end

    add_index :agent_rpc_operation_receipts,
      %i[agent_rpc_invocation_id operation_id],
      unique: true,
      name: "idx_agent_rpc_operation_receipts"
  end
end
