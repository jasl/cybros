class RelaxLegacyRuntimeEntrypointColumns < ActiveRecord::Migration[8.1]
  def change
    change_column_null :conversations, :agent_program_id, true
    change_column_null :automations, :agent_program_id, true
    change_column_null :automations, :execution_target_id, true
  end
end
