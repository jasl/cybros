class DropLegacyConversationWorkspaceColumns < ActiveRecord::Migration[8.1]
  def change
    remove_index :conversations, :logical_workspace_key, if_exists: true

    remove_column :conversations, :logical_workspace_initialized_at, :datetime, if_exists: true
    remove_column :conversations, :logical_workspace_key, :string, if_exists: true
    remove_column :conversations, :logical_workspace_root_path, :string, if_exists: true
  end
end
