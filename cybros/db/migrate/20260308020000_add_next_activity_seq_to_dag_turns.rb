class AddNextActivitySeqToDAGTurns < ActiveRecord::Migration[8.2]
  def change
    add_column :dag_turns, :next_activity_seq, :bigint, null: false, default: 0
  end
end
