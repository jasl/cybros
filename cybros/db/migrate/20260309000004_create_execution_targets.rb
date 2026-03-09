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

    add_index :execution_targets, %i[execution_location_id workspace_id], unique: true, name: "idx_execution_targets_on_location_workspace"
    add_foreign_key :execution_targets,
      :workspaces,
      column: %i[workspace_id execution_location_id],
      primary_key: %i[id execution_location_id],
      name: "fk_execution_targets_workspace_location"
  end
end
