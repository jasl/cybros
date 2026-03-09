class HardenProgrammableAgentBindings < ActiveRecord::Migration[8.2]
  def change
    change_column_null :conversation_runs, :snapshot_version, false
    change_column_null :conversation_runs, :effective_permission_mode, false
    change_column_null :conversation_runs, :agent_program_id, false
    change_column_null :conversation_runs, :contract_fingerprint, false
    change_column_null :conversation_runs, :agent_deployment_id, false
    change_column_null :conversation_runs, :deployment_fingerprint, false
    change_column_null :conversation_runs, :deployment_activated_at, false

    add_index :agent_deployments,
      %i[id agent_program_id],
      unique: true,
      name: "idx_agent_deployments_id_program"

    add_index :run_drafts, %i[agent_deployment_id agent_program_id], name: "idx_run_drafts_deploy_program"
    add_foreign_key :run_drafts,
      :agent_deployments,
      column: %i[agent_deployment_id agent_program_id],
      primary_key: %i[id agent_program_id],
      name: "fk_run_drafts_deployment_program"

    add_index :conversation_runs,
      %i[agent_deployment_id agent_program_id],
      name: "idx_conversation_runs_deploy_program"
    add_foreign_key :conversation_runs,
      :agent_deployments,
      column: %i[agent_deployment_id agent_program_id],
      primary_key: %i[id agent_program_id],
      name: "fk_conversation_runs_deploy_program"

    add_index :agent_rpc_invocations,
      %i[id agent_deployment_id],
      unique: true,
      name: "idx_agent_rpc_invocations_id_deploy"

    add_index :agent_rpc_sessions,
      %i[agent_rpc_invocation_id agent_deployment_id],
      name: "idx_agent_rpc_sessions_invocation_deploy"
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
  end
end
