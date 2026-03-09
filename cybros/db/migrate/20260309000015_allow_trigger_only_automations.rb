class AllowTriggerOnlyAutomations < ActiveRecord::Migration[8.1]
  def change
    change_column_null :automations, :schedule_kind, true
  end
end
