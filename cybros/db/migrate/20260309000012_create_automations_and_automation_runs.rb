class CreateAutomationsAndAutomationRuns < ActiveRecord::Migration[8.2]
  def change
    create_table :automations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: true
      t.references :agent_program, null: false, type: :uuid, foreign_key: true
      t.references :execution_target, null: false, type: :uuid, foreign_key: true
      t.string :permission_mode, null: false, default: "full_access"
      t.string :status, null: false, default: "active"
      t.string :schedule_kind, null: false
      t.string :schedule_rrule
      t.string :schedule_timezone
      t.jsonb :task_payload, null: false, default: {}
      t.timestamps
    end

    create_table :automation_runs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :automation, null: false, type: :uuid, foreign_key: true
      t.references :initiated_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.references :conversation_run, type: :uuid, foreign_key: true
      t.string :status, null: false
      t.jsonb :approval_state, null: false, default: {}
      t.datetime :scheduled_for, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.jsonb :snapshot, null: false, default: {}
      t.timestamps
    end

    add_index :automation_runs, %i[automation_id scheduled_for], name: "idx_automation_runs_schedule"
    add_foreign_key :run_drafts, :automations, column: :automation_id
  end
end
