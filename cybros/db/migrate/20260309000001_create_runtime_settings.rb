class CreateRuntimeSettings < ActiveRecord::Migration[8.2]
  def change
    create_table :runtime_settings, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :scope_key, null: false, default: "instance"
      t.integer :default_worker_concurrency, null: false, default: 8
      t.jsonb :queue_overrides, null: false, default: {}
      t.jsonb :alert_thresholds, null: false, default: {}
      t.timestamps
    end

    add_index :runtime_settings, :scope_key, unique: true
  end
end
