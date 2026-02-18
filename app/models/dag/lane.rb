module DAG
  class Lane < ApplicationRecord
    self.table_name = "dag_lanes"

    MAIN = "main"
    BRANCH = "branch"

    ROLES = [MAIN, BRANCH].freeze

    enum :role, ROLES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :lanes
    belongs_to :parent_lane, class_name: "DAG::Lane", optional: true
    has_many :child_lanes,
             class_name: "DAG::Lane",
             foreign_key: :parent_lane_id,
             dependent: :nullify,
             inverse_of: :parent_lane

    belongs_to :forked_from_node, class_name: "DAG::Node", optional: true
    belongs_to :root_node, class_name: "DAG::Node", optional: true
    belongs_to :merged_into_lane, class_name: "DAG::Lane", optional: true

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :lane

    validates :role, inclusion: { in: ROLES }
    validate :lane_relationships_must_match_graph

    def archived?
      archived_at.present?
    end

    private

      def lane_relationships_must_match_graph
        return if graph_id.blank?

        if parent_lane && parent_lane.graph_id != graph_id
          errors.add(:parent_lane_id, "must belong to the same graph")
        end

        if merged_into_lane && merged_into_lane.graph_id != graph_id
          errors.add(:merged_into_lane_id, "must belong to the same graph")
        end

        if forked_from_node && forked_from_node.graph_id != graph_id
          errors.add(:forked_from_node_id, "must belong to the same graph")
        end

        if root_node
          if root_node.graph_id != graph_id
            errors.add(:root_node_id, "must belong to the same graph")
          end

          if root_node.lane_id != id
            errors.add(:root_node_id, "must belong to this lane")
          end
        end
      end
  end
end
