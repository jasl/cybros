class AddConversationWorkspaceFields < ActiveRecord::Migration[8.1]
  def change
    change_table :conversations, bulk: true do |t|
      t.string :logical_workspace_key
      t.string :logical_workspace_root_path
      t.datetime :logical_workspace_initialized_at
    end

    add_index :conversations, :logical_workspace_key, unique: true
  end
end
