module DAG
  class NodeVisibilityPatch < ApplicationRecord
    self.table_name = "dag_node_visibility_patches"

    belongs_to :graph, class_name: "DAG::Graph"
    belongs_to :node, class_name: "DAG::Node"

    validates :graph_id, :node_id, presence: true
    validate :node_belongs_to_graph

    private

      def node_belongs_to_graph
        return if node.blank? || graph_id.blank?
        return if node.graph_id == graph_id

        errors.add(:node_id, "must belong to the same graph")
      end
  end
end
