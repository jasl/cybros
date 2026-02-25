class CreateConduitsDirectives < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_directives, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account,   type: :uuid, null: false, foreign_key: true, index: true
      t.references :facility,  type: :uuid, null: false,
                   foreign_key: { to_table: :conduits_facilities }, index: true
      t.references :territory, type: :uuid, null: true,
                   foreign_key: { to_table: :conduits_territories }, index: true

      t.references :requested_by_user, type: :uuid, null: false,
                   foreign_key: { to_table: :users }, index: true
      t.references :approved_by_user,  type: :uuid, null: true,
                   foreign_key: { to_table: :users }, index: true

      t.string :state,           null: false, default: "queued"
      t.string :sandbox_profile, null: false, default: "untrusted"

      t.jsonb :requested_capabilities, null: false, default: {}
      t.jsonb :effective_capabilities, null: false, default: {}

      t.string :cwd
      t.jsonb  :env_allowlist, null: false, default: []
      t.jsonb  :env_refs,      null: false, default: []
      t.string :command,       null: false
      t.string :shell

      t.integer :timeout_seconds, null: false, default: 0
      t.jsonb   :limits,          null: false, default: {}

      # New fields per design doc v0.6
      t.string :runtime_ref                     # container image digest / microVM kernel+rootfs digest
      t.jsonb :egress_proxy_policy_snapshot    # effective allowlist rules snapshot for audit

      t.integer :exit_code
      t.string  :finished_status                             # succeeded/failed/canceled/timed_out
      t.boolean :stdout_truncated, null: false, default: false
      t.boolean :stderr_truncated, null: false, default: false
      t.boolean :diff_truncated,   null: false, default: false
      t.string :result_hash

      t.integer :stdout_bytes, null: false, default: 0
      t.integer :stderr_bytes, null: false, default: 0

      t.string :snapshot_before                              # git HEAD hash before execution
      t.string :snapshot_after
      # git HEAD hash after execution

      t.jsonb  :artifacts_manifest, null: false, default: {}

      t.string :nexus_version
      t.string :sandbox_version

      t.datetime :lease_expires_at
      t.datetime :last_heartbeat_at

      t.datetime :cancel_requested_at
      t.datetime :finished_at
      t.timestamps

      t.index %i[state account_id sandbox_profile],
              name: "idx_directives_state_account_profile"
      t.index %i[state lease_expires_at],
              name: "idx_directives_state_lease_expires"
    end
  end
end
