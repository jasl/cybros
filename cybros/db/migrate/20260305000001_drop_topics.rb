class DropTopics < ActiveRecord::Migration[8.2]
  def change
    drop_table :topics do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: false
      t.string :role, null: false
      t.string :title
      t.text :summary
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
  end
end
