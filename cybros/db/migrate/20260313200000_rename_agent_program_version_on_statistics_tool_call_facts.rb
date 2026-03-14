class RenameAgentProgramVersionOnStatisticsToolCallFacts < ActiveRecord::Migration[8.0]
  def up
    return if column_exists?(:statistics_tool_call_facts, :agent_capabilities_version)
    return unless column_exists?(:statistics_tool_call_facts, :agent_program_version)

    rename_column :statistics_tool_call_facts, :agent_program_version, :agent_capabilities_version
  end

  def down
    return if column_exists?(:statistics_tool_call_facts, :agent_program_version)
    return unless column_exists?(:statistics_tool_call_facts, :agent_capabilities_version)

    rename_column :statistics_tool_call_facts, :agent_capabilities_version, :agent_program_version
  end
end
