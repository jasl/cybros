class AddClaimAfterAtToDAGNodes < ActiveRecord::Migration[8.2]
  def change
    add_column :dag_nodes, :claim_after_at, :datetime

    add_index :dag_nodes,
              %i[graph_id state claim_after_at],
              where: "compressed_at IS NULL AND state = 'pending'",
              name: "index_dag_nodes_claim_after"
  end
end
