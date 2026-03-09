class AddDispatchKeyToAutomationRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :automation_runs, :dispatch_key, :string
    add_index :automation_runs, %i[automation_id dispatch_key],
      unique: true,
      where: "dispatch_key IS NOT NULL",
      name: "idx_automation_runs_dispatch_key"
  end
end
