module DAG
  class Turn < ApplicationRecord
    self.table_name = "dag_turns"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :turns
    belongs_to :subgraph, class_name: "DAG::Subgraph", inverse_of: :turns

    has_many :nodes,
             class_name: "DAG::Node",
             foreign_key: :turn_id,
             inverse_of: :turn

    validate :subgraph_must_match_graph

    private

      def subgraph_must_match_graph
        return if graph_id.blank? || subgraph_id.blank?
        return if subgraph.blank?

        if subgraph.graph_id != graph_id
          errors.add(:subgraph_id, "must belong to the same graph")
        end
      end
  end
end
