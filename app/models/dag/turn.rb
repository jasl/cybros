module DAG
  class Turn < ApplicationRecord
    self.table_name = "dag_turns"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :turns
    belongs_to :lane, class_name: "DAG::Lane", inverse_of: :turn_records

    has_many :nodes,
             class_name: "DAG::Node",
             foreign_key: :turn_id,
             inverse_of: :turn

    validate :lane_must_match_graph

    private

      def lane_must_match_graph
        return if graph_id.blank? || lane_id.blank?
        return if lane.blank?

        if lane.graph_id != graph_id
          errors.add(:lane_id, "must belong to the same graph")
        end
      end
  end
end
