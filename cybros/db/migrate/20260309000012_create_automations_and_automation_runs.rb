class CreateAutomationsAndAutomationRuns < ActiveRecord::Migration[8.2]
  def change
    create_table :automations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.references :agent_program, null: false, type: :uuid, foreign_key: true
      t.references :execution_target, null: false, type: :uuid, foreign_key: true
      t.string :permission_mode, null: false, default: "full_access"
      t.string :status, null: false, default: "active"
      t.string :schedule_kind
      t.string :schedule_rrule
      t.string :schedule_timezone
      t.jsonb :task_payload, null: false, default: {}
      t.string :trigger_kind
      t.jsonb :trigger_payload, null: false, default: {}
      t.timestamps
    end

    change_table :conversations, bulk: true do |t|
      t.references :automation, type: :uuid, foreign_key: true, index: true
      t.string :automation_dispatch_key
      t.datetime :automation_triggered_at
    end

    add_index :conversations, %i[automation_id automation_dispatch_key],
      unique: true,
      where: "automation_dispatch_key IS NOT NULL",
      name: "idx_conversations_automation_dispatch_key"
  end
end
