class CreateConduitsPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :conduits_policies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account,  type: :uuid, null: true, foreign_key: true, index: true

      # Polymorphic scope: the entity this policy applies to.
      # Possible types: nil (global default), "Account", "User",
      #   "Conduits::Territory", "Conduits::Facility"
      # A directive-level override is stored inline on the directive itself
      # (requested_capabilities / effective_capabilities), not as a separate policy row.
      t.references :scope, polymorphic: true, index: true
      t.integer :priority, null: false, default: 0  # lower = broader; higher = more specific

      t.string :name, null: false                     # human-readable label, e.g. "Default", "CI runners"

      # Capability sections (JSON)
      t.jsonb :fs,                    null: false, default: {}  # path read/write allowlist
      t.jsonb :net,                   null: false, default: {}  # none/allowlist/unrestricted + entries
      t.jsonb :secrets,               null: false, default: {}  # secret ref allowlist
      t.jsonb :sandbox_profile_rules, null: false, default: {}  # conditions for trusted/host
      t.jsonb :approval,              null: false, default: {}  # which capabilities require human approval

      t.boolean :active, null: false, default: true

      t.timestamps
    end
  end
end
