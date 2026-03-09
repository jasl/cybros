class AddTriggerFieldsToAutomations < ActiveRecord::Migration[8.1]
  def change
    add_column :automations, :trigger_kind, :string
    add_column :automations, :trigger_payload, :jsonb, null: false, default: {}
  end
end
