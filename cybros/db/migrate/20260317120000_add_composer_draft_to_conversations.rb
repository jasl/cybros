class AddComposerDraftToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :composer_draft, :jsonb, null: false, default: {}
  end
end
