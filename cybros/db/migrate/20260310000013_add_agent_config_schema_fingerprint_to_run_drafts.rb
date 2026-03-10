class AddAgentConfigSchemaFingerprintToRunDrafts < ActiveRecord::Migration[8.2]
  def up
    add_column :run_drafts, :agent_config_schema_fingerprint, :string

    execute <<~SQL.squish
      UPDATE run_drafts
      SET agent_config_schema_fingerprint = conversation_runs.agent_config_schema_fingerprint
      FROM conversation_runs
      WHERE run_drafts.materialized_conversation_run_id = conversation_runs.id
        AND run_drafts.agent_config_schema_fingerprint IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE run_drafts
      SET agent_config_schema_fingerprint = conversations.agent_config_schema_fingerprint
      FROM conversations
      WHERE run_drafts.conversation_id = conversations.id
        AND run_drafts.agent_config_schema_fingerprint IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE run_drafts
      SET agent_config_schema_fingerprint = agent_programs.config_schema_fingerprint
      FROM agent_programs
      WHERE run_drafts.agent_program_id = agent_programs.id
        AND run_drafts.agent_config_schema_fingerprint IS NULL
    SQL

    change_column_null :run_drafts, :agent_config_schema_fingerprint, false
  end

  def down
    remove_column :run_drafts, :agent_config_schema_fingerprint
  end
end
