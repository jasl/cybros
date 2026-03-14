class DropLegacyRuntimeSchema < ActiveRecord::Migration[8.1]
  def up
    remove_conversation_runtime_columns!
    remove_automation_runtime_columns!
    remove_run_draft_runtime_columns!
    remove_conversation_run_runtime_columns!
    remove_agent_runtime_columns!
    remove_recognized_deployment_runtime_columns!
    remove_statistics_runtime_columns!
    drop_legacy_runtime_tables!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "legacy runtime schema removal is destructive"
  end

  private

    def remove_conversation_runtime_columns!
      remove_foreign_key :conversations, column: :default_execution_target_id if foreign_key_exists?(:conversations, column: :default_execution_target_id)
      remove_index :conversations, :agent_program_id if index_exists?(:conversations, :agent_program_id)
      remove_index :conversations, :default_execution_target_id if index_exists?(:conversations, :default_execution_target_id)
      remove_column :conversations, :agent_program_id if column_exists?(:conversations, :agent_program_id)
      remove_column :conversations, :default_execution_target_id if column_exists?(:conversations, :default_execution_target_id)
    end

    def remove_automation_runtime_columns!
      remove_foreign_key :automations, column: :execution_target_id if foreign_key_exists?(:automations, column: :execution_target_id)
      remove_index :automations, :agent_program_id if index_exists?(:automations, :agent_program_id)
      remove_index :automations, :execution_target_id if index_exists?(:automations, :execution_target_id)
      remove_column :automations, :agent_program_id if column_exists?(:automations, :agent_program_id)
      remove_column :automations, :execution_target_id if column_exists?(:automations, :execution_target_id)
    end

    def remove_run_draft_runtime_columns!
      remove_foreign_key :run_drafts, name: "fk_run_drafts_deployment_program" if foreign_key_exists?(:run_drafts, name: "fk_run_drafts_deployment_program")
      remove_foreign_key :run_drafts, column: :proposed_execution_target_id if foreign_key_exists?(:run_drafts, column: :proposed_execution_target_id)
      remove_index :run_drafts, name: "idx_run_drafts_deploy_program" if index_exists?(:run_drafts, name: "idx_run_drafts_deploy_program")
      remove_index :run_drafts, :agent_deployment_id if index_exists?(:run_drafts, :agent_deployment_id)
      remove_index :run_drafts, :agent_program_id if index_exists?(:run_drafts, :agent_program_id)
      remove_index :run_drafts, :proposed_execution_target_id if index_exists?(:run_drafts, :proposed_execution_target_id)
      remove_column :run_drafts, :agent_deployment_id if column_exists?(:run_drafts, :agent_deployment_id)
      remove_column :run_drafts, :agent_program_id if column_exists?(:run_drafts, :agent_program_id)
      remove_column :run_drafts, :proposed_execution_target_id if column_exists?(:run_drafts, :proposed_execution_target_id)
    end

    def remove_conversation_run_runtime_columns!
      remove_foreign_key :conversation_runs, name: "fk_conversation_runs_deploy_program" if foreign_key_exists?(:conversation_runs, name: "fk_conversation_runs_deploy_program")
      remove_foreign_key :conversation_runs, column: :execution_target_id if foreign_key_exists?(:conversation_runs, column: :execution_target_id)
      remove_index :conversation_runs, name: "idx_conversation_runs_deploy_program" if index_exists?(:conversation_runs, name: "idx_conversation_runs_deploy_program")
      remove_index :conversation_runs, :agent_deployment_id if index_exists?(:conversation_runs, :agent_deployment_id)
      remove_index :conversation_runs, :agent_program_id if index_exists?(:conversation_runs, :agent_program_id)
      remove_index :conversation_runs, :execution_target_id if index_exists?(:conversation_runs, :execution_target_id)
      remove_column :conversation_runs, :agent_deployment_id if column_exists?(:conversation_runs, :agent_deployment_id)
      remove_column :conversation_runs, :agent_program_id if column_exists?(:conversation_runs, :agent_program_id)
      remove_column :conversation_runs, :execution_target_id if column_exists?(:conversation_runs, :execution_target_id)
    end

    def remove_agent_runtime_columns!
      remove_foreign_key :agents, column: :legacy_agent_program_id if foreign_key_exists?(:agents, column: :legacy_agent_program_id)
      remove_foreign_key :agents, column: :legacy_execution_target_id if foreign_key_exists?(:agents, column: :legacy_execution_target_id)
      remove_index :agents, :legacy_agent_program_id if index_exists?(:agents, :legacy_agent_program_id)
      remove_column :agents, :legacy_agent_program_id if column_exists?(:agents, :legacy_agent_program_id)
      remove_column :agents, :legacy_execution_target_id if column_exists?(:agents, :legacy_execution_target_id)
    end

    def remove_recognized_deployment_runtime_columns!
      remove_foreign_key :recognized_deployments, column: :legacy_agent_deployment_id if foreign_key_exists?(:recognized_deployments, column: :legacy_agent_deployment_id)
      remove_column :recognized_deployments, :legacy_agent_deployment_id if column_exists?(:recognized_deployments, :legacy_agent_deployment_id)
    end

    def remove_statistics_runtime_columns!
      remove_index :statistics_tool_call_facts, name: "idx_tool_call_facts_sample_origin_agent_program" if index_exists?(:statistics_tool_call_facts, name: "idx_tool_call_facts_sample_origin_agent_program")
      remove_column :statistics_tool_call_facts, :agent_program_id if column_exists?(:statistics_tool_call_facts, :agent_program_id)
    end

    def drop_legacy_runtime_tables!
      drop_table :agent_deployments if table_exists?(:agent_deployments)
      drop_table :agent_programs if table_exists?(:agent_programs)
      drop_table :execution_targets if table_exists?(:execution_targets)
      drop_table :workspaces if table_exists?(:workspaces)
      drop_table :execution_locations if table_exists?(:execution_locations)
    end
end
