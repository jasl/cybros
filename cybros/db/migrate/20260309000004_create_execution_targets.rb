class CreateExecutionTargets < ActiveRecord::Migration[8.2]
  def change
    create_table :execution_targets, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :execution_location, null: false, type: :uuid, foreign_key: true
      t.references :workspace, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.boolean :sandboxed, null: false, default: false
      t.integer :max_concurrent_tasks_override
      t.integer :max_queued_tasks_override
      t.integer :default_timeout_s_override
      t.integer :cpu_limit_millicores_override
      t.integer :memory_limit_mb_override
      t.timestamps
    end
  end
end
