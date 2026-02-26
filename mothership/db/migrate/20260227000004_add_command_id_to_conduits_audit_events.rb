class AddCommandIdToConduitsAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :conduits_audit_events, :command,
                  type: :uuid,
                  foreign_key: { to_table: :conduits_commands },
                  null: true,
                  index: true
  end
end
