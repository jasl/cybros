class CreateConversations < ActiveRecord::Migration[8.2]
  def change
    create_table :conversations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :title
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
  end
end
