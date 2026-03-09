class NullifyAutomationRunConversationRunOnDelete < ActiveRecord::Migration[8.1]
  def change
    # Automation runs are removed; conversation runs no longer have a historical back-link.
  end
end
