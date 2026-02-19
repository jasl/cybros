module DAG
  class NodeEvent < ApplicationRecord
    self.table_name = "dag_node_events"

    OUTPUT_DELTA = "output_delta"
    PROGRESS = "progress"
    LOG = "log"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :node_events
    belongs_to :node, class_name: "DAG::Node", inverse_of: :node_events

    validates :kind, presence: true

    before_validation :normalize_payload

    scope :ordered, -> { order(:id) }

    private

      def normalize_payload
        if payload.is_a?(Hash)
          self.payload = payload.deep_stringify_keys
        else
          self.payload = {}
        end
      end
  end
end
