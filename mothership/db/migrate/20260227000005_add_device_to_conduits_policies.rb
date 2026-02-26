class AddDeviceToConduitsPolicies < ActiveRecord::Migration[8.1]
  def change
    add_column :conduits_policies, :device, :jsonb, default: {}, null: false
  end
end
