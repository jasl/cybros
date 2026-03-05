class AddTurnAndBodyToDAGNodeEvents < ActiveRecord::Migration[8.2]
  def change
    change_table :dag_node_events, bulk: true do |t|
      t.uuid :turn_id
      t.uuid :body_id
    end
  end
end
