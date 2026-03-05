class AddIncludeDeletedVisibilityIndexToDAGTurns < ActiveRecord::Migration[8.2]
  def change
    add_index :dag_turns,
              %i[graph_id lane_id id],
              where: "anchor_node_id_including_deleted IS NOT NULL",
              name: "index_dag_turns_graph_lane_visible_including_deleted"
  end
end
