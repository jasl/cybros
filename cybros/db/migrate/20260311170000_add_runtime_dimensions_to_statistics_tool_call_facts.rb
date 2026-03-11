class AddRuntimeDimensionsToStatisticsToolCallFacts < ActiveRecord::Migration[8.1]
  def change
    change_table :statistics_tool_call_facts, bulk: true do |t|
      t.string :logical_tool_name
      t.string :capability_registry_snapshot_id
      t.string :kernel_capability_registry_version
      t.string :tool_surface_id
      t.string :tool_surface_label
      t.string :implementation_source
      t.string :implementation_ref
      t.uuid :agent_program_id
      t.string :agent_program_version
    end

    add_index :statistics_tool_call_facts,
              %i[sample_origin implementation_source],
              name: "idx_tool_call_facts_sample_origin_impl_source"
    add_index :statistics_tool_call_facts,
              %i[sample_origin logical_tool_name],
              name: "idx_tool_call_facts_sample_origin_logical_name"
    add_index :statistics_tool_call_facts,
              %i[sample_origin tool_surface_id],
              name: "idx_tool_call_facts_sample_origin_tool_surface"
    add_index :statistics_tool_call_facts,
              %i[sample_origin agent_program_id],
              name: "idx_tool_call_facts_sample_origin_agent_program"
  end
end
