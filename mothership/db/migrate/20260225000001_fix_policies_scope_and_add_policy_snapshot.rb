class FixPoliciesScopeAndAddPolicySnapshot < ActiveRecord::Migration[8.1]
  def change
    # scope_id was bigint but all scope targets (Account, User, Territory, Facility)
    # use UUID primary keys — polymorphic lookups would silently fail.
    # Table is empty (no evaluation logic existed), so safe to replace.
    remove_index :conduits_policies, name: "index_conduits_policies_on_scope"
    remove_column :conduits_policies, :scope_id, :bigint
    add_column :conduits_policies, :scope_id, :uuid
    add_index :conduits_policies, [:scope_type, :scope_id], name: "index_conduits_policies_on_scope"

    # Capture the resolved policy at creation time for audit trail.
    add_column :conduits_directives, :policy_snapshot, :jsonb
  end
end
