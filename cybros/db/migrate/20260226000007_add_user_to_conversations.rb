class AddUserToConversations < ActiveRecord::Migration[8.2]
  def change
    change_table :conversations, bulk: true do |t|
      t.references :user, type: :uuid, null: true, foreign_key: true
    end
  end
end
