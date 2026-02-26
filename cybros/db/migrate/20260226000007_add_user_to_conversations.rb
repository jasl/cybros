class AddUserToConversations < ActiveRecord::Migration[8.2]
  def up
    add_reference :conversations, :user, type: :uuid, null: true, foreign_key: true

    if (user_id = User.order(:created_at).limit(1).pick(:id))
      execute <<~SQL.squish
        update conversations
        set user_id = '#{user_id}'
        where user_id is null
      SQL
    end

    change_column_null :conversations, :user_id, false
  end

  def down
    remove_reference :conversations, :user, foreign_key: true
  end
end
