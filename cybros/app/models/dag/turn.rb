module DAG
  class Turn < ApplicationRecord
    self.table_name = "dag_turns"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :turns
    belongs_to :lane, class_name: "DAG::Lane", inverse_of: :turns

    has_many :nodes,
             class_name: "DAG::Node",
             foreign_key: :turn_id,
             inverse_of: :turn

    validate :lane_must_match_graph

    def start_message_node_id(include_deleted: false)
      if include_deleted
        anchor_node_id_including_deleted
      else
        anchor_node_id
      end
    end

    def end_message_node_id(include_deleted: false)
      messages = message_nodes(mode: :preview, include_deleted: include_deleted)
      messages.last&.fetch("node_id", nil)
    end

    def allocate_activity_sequence!
      self.class.allocate_activity_sequence!(graph_id: graph_id, lane_id: lane_id, turn_id: id)
    end

    def message_nodes(mode: :preview, include_deleted: false)
      candidate_types = graph.transcript_candidate_node_types
      return [] if candidate_types.empty?

      node_scope = graph.nodes.active.where(lane_id: lane_id, turn_id: id, node_type: candidate_types)
      node_scope = node_scope.where(deleted_at: nil) unless include_deleted

      node_records =
        node_scope
          .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id)
          .order(:id)
          .to_a

      projection = DAG::TranscriptProjection.new(graph: graph)
      projection.project(node_records: node_records, mode: mode)
    end

    private

      def self.allocate_activity_sequence!(graph_id:, lane_id:, turn_id:)
        now = Time.current

        with_connection do |connection|
          sql = <<~SQL
            UPDATE dag_turns
               SET next_activity_seq = next_activity_seq + 1,
                   updated_at = #{connection.quote(now)}
             WHERE graph_id = #{connection.quote(graph_id)}
               AND lane_id = #{connection.quote(lane_id)}
               AND id = #{connection.quote(turn_id)}
            RETURNING next_activity_seq
          SQL

          value = connection.select_value(sql)
          raise ActiveRecord::RecordNotFound, "turn not found for activity sequence allocation" if value.nil?

          value.to_i
        end
      end

      def lane_must_match_graph
        return if graph_id.blank? || lane_id.blank?
        return if lane.blank?

        if lane.graph_id != graph_id
          errors.add(:lane_id, "must belong to the same graph")
        end
      end
  end
end
