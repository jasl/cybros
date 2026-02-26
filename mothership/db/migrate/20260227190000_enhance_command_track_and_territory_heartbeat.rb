class EnhanceCommandTrackAndTerritoryHeartbeat < ActiveRecord::Migration[8.1]
  def change
    # --- Territory: runtime_status for load-aware scheduling ---
    add_column :conduits_territories, :runtime_status, :jsonb, default: {}, null: false

    # --- Command: awaiting_approval state, policy gate, idempotency ---
    add_column :conduits_commands, :policy_snapshot, :jsonb
    add_column :conduits_commands, :result_hash, :string
    add_column :conduits_commands, :approved_by_user_id, :uuid
    add_column :conduits_commands, :approval_reasons, :jsonb, default: [], null: false

    add_foreign_key :conduits_commands, :users, column: :approved_by_user_id
    add_index :conduits_commands, :approved_by_user_id
  end
end
