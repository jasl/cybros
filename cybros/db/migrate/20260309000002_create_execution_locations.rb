class CreateExecutionLocations < ActiveRecord::Migration[8.2]
  def change
    create_table :execution_locations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.string :platform, null: false
      t.string :status, null: false, default: "active"
      t.string :trust_group, null: false
      t.string :environment, null: false
      t.text :tags, array: true, null: false, default: []
      t.integer :max_concurrent_tasks, null: false
      t.integer :max_queued_tasks, null: false
      t.integer :default_timeout_s, null: false
      t.integer :cpu_limit_millicores
      t.integer :memory_limit_mb
      t.timestamps
    end
  end
end
