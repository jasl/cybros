class CreateAgentPrograms < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_programs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.text :description
      t.string :profile_source
      t.string :local_path
      t.jsonb :args, null: false, default: {}
      t.string :active_persona
      t.timestamps
    end
  end
end

