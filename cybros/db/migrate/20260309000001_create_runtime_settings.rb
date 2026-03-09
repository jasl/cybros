class CreateRuntimeSettings < ActiveRecord::Migration[8.2]
  def change
    create_table :runtime_settings, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.integer :default_worker_concurrency, null: false, default: 8
      t.jsonb :queue_overrides, null: false, default: {}
      t.jsonb :alert_thresholds, null: false, default: {}
      t.timestamps
    end
  end
end
