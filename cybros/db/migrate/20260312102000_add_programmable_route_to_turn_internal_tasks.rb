class AddProgrammableRouteToTurnInternalTasks < ActiveRecord::Migration[8.2]
  def change
    change_table :turn_internal_tasks, bulk: true do |t|
      t.string :effective_tool_id
      t.string :implementation_source
      t.string :implementation_ref
    end
  end
end
