class CreateRuntimeGovernanceAdmissionState < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_budget_reservations, id: :uuid do |t|
      t.references :provider_credential, null: false, foreign_key: { to_table: :llm_provider_credentials }, type: :uuid
      t.string :provider_request_id, null: false
      t.integer :request_units, null: false, default: 1
      t.integer :estimated_tokens, null: false, default: 0
      t.integer :actual_tokens
      t.datetime :reserved_until, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :reconciliation_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :provider_budget_reservations, [:provider_credential_id, :provider_request_id],
      unique: true,
      name: "idx_provider_budget_reservations_request"

    create_table :execution_capacity_leases, id: :uuid do |t|
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.string :execution_request_id, null: false
      t.string :holder_type, null: false
      t.string :holder_id, null: false
      t.integer :slots, null: false, default: 1
      t.datetime :lease_expires_at, null: false
      t.datetime :heartbeat_at, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :recovery_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :execution_capacity_leases, [:subject_type, :subject_id, :execution_request_id],
      unique: true,
      name: "idx_execution_capacity_leases_subject_request"
    add_index :execution_capacity_leases, [:subject_type, :subject_id, :status],
      name: "idx_execution_capacity_leases_subject_status"

    create_table :runtime_waits, id: :uuid do |t|
      t.string :owner_type, null: false
      t.string :owner_id, null: false
      t.string :reason_type, null: false
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.datetime :retry_at, null: false
      t.string :ordering_key, null: false
      t.jsonb :details, null: false, default: {}
      t.string :status, null: false, default: "parked"
      t.timestamps
    end
    add_index :runtime_waits, [:reason_type, :subject_type, :subject_id, :status, :retry_at],
      name: "idx_runtime_waits_ready_lookup"
    add_index :runtime_waits, [:reason_type, :subject_type, :subject_id, :status, :ordering_key],
      name: "idx_runtime_waits_fifo_lookup"
    add_index :runtime_waits, [:owner_type, :owner_id, :reason_type, :subject_type, :subject_id],
      unique: true,
      where: "status = 'parked'",
      name: "idx_runtime_waits_owner_reason_subject_parked"
  end
end
