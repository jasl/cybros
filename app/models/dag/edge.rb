module DAG
  class Edge < ApplicationRecord
    self.table_name = "dag_edges"

    SEQUENCE = "sequence"
    DEPENDENCY = "dependency"
    BRANCH = "branch"

    EDGE_TYPES = [SEQUENCE, DEPENDENCY, BRANCH].freeze
    BLOCKING_EDGE_TYPES = [SEQUENCE, DEPENDENCY].freeze

    enum :edge_type, EDGE_TYPES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :edges
    belongs_to :from_node, class_name: "DAG::Node", inverse_of: :outgoing_edges
    belongs_to :to_node, class_name: "DAG::Node", inverse_of: :incoming_edges

    validates :edge_type, inclusion: { in: EDGE_TYPES }
    validates :graph_id, :from_node_id, :to_node_id, presence: true

    validate :nodes_belong_to_same_graph
    validate :must_not_introduce_cycle, on: :create

    scope :active, -> { where(compressed_at: nil) }

    private

      def nodes_belong_to_same_graph
        if from_node && from_node.graph_id != graph_id
          errors.add(:from_node_id, "must belong to the same graph")
        end

        if to_node && to_node.graph_id != graph_id
          errors.add(:to_node_id, "must belong to the same graph")
        end
      end

      def must_not_introduce_cycle
        return if errors.any?
        return if graph_id.blank? || from_node_id.blank? || to_node_id.blank?

        DAG::Graph.lock.where(id: graph_id).pick(:id)

        if path_exists?(from: to_node_id, to: from_node_id)
          errors.add(:base, "edge would introduce a cycle")
        end
      end

      def path_exists?(from:, to:)
        self.class.with_connection do |connection|
          from_quoted = connection.quote(from)
          to_quoted = connection.quote(to)
          graph_quoted = connection.quote(graph_id)

          sql = <<~SQL
            WITH RECURSIVE search(node_id) AS (
              SELECT #{from_quoted}::uuid
              UNION
              SELECT e.to_node_id
              FROM dag_edges e
              JOIN search s ON e.from_node_id = s.node_id
              WHERE e.graph_id = #{graph_quoted}
                AND e.compressed_at IS NULL
            )
            SELECT 1 FROM search WHERE node_id = #{to_quoted}::uuid LIMIT 1
          SQL

          connection.select_value(sql).present?
        end
      end
  end
end
