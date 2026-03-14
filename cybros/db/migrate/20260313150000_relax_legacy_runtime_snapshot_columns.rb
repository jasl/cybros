class RelaxLegacyRuntimeSnapshotColumns < ActiveRecord::Migration[8.1]
  def change
    change_column_null :run_drafts, :agent_program_id, true
    change_column_null :run_drafts, :agent_deployment_id, true
    change_column_null :conversation_runs, :agent_program_id, true
    change_column_null :conversation_runs, :agent_deployment_id, true
  end
end
