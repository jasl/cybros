class RenameRunDraftPreparedPlanToPlanning < ActiveRecord::Migration[8.1]
  def change
    rename_column :run_drafts, :prepared_plan, :planning
  end
end
