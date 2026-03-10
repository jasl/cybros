class AddAgentSourceFieldsAndWorkspaceRoot < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_programs, :source_kind, :string, null: false, default: "custom"
    add_column :agent_programs, :bundled_agent_key, :string
    add_reference :agent_programs,
                  :forked_from_agent_program,
                  type: :uuid,
                  foreign_key: { to_table: :agent_programs }
    add_index :agent_programs, %i[source_kind bundled_agent_key], unique: true, where: "source_kind = 'bundled'", name: "idx_agent_programs_bundled_key"

    add_column :runtime_settings, :agent_workspace_root, :string
  end
end
