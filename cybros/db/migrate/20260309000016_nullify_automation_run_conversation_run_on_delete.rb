class NullifyAutomationRunConversationRunOnDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :automation_runs, :conversation_runs
    add_foreign_key :automation_runs, :conversation_runs, on_delete: :nullify
  end
end
