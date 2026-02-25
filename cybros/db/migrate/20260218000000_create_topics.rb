class CreateTopics < ActiveRecord::Migration[8.2]
  def change
    create_table :topics, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, foreign_key: true, null: false

      t.string :role, null: false
      t.check_constraint(
        "role IN ('main','branch')",
        name: "check_topics_role_enum"
      )

      t.string :title
      t.text :summary
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :topics, :conversation_id,
              unique: true,
              where: "role = 'main'",
              name: "index_topics_main_per_conversation"
  end
end
