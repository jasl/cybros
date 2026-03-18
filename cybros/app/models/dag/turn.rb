module DAG
  class Turn < ApplicationRecord
    self.table_name = "dag_turns"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :turns
    belongs_to :lane, class_name: "DAG::Lane", inverse_of: :turns

    has_many :nodes,
             class_name: "DAG::Node",
             foreign_key: :turn_id,
             inverse_of: :turn
    has_many :owned_subagent_threads,
             class_name: "SubagentThread",
             foreign_key: :owner_turn_id,
             dependent: :restrict_with_exception,
             inverse_of: :owner_turn

    validate :lane_must_match_graph

    def start_message_node_id(include_deleted: false)
      if include_deleted
        head_node_id_including_deleted
      else
        head_node_id
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

    def execution_status
      self[:execution_status].to_s.presence
    end

    def execution_phase
      self[:execution_phase].to_s.presence
    end

    def execution_diagnostic_level
      self[:execution_diagnostic_level].to_s.presence
    end

    def execution_event_cursor
      self[:execution_event_cursor]
    end

    def execution_summary
      summary = self[:execution_summary]
      summary.is_a?(Hash) ? summary : {}
    end

    def execution_hidden_summary
      summary = self[:execution_hidden_summary]
      summary.is_a?(Hash) ? summary : {}
    end

    def execution_activity_count
      self[:execution_activity_count].to_i
    end

    def execution_preview_activities
      Array(self[:execution_preview_activities]).select { |activity| activity.is_a?(Hash) }
    end

    def execution_updated_at
      self[:execution_updated_at]
    end

    private

      def self.refresh_execution_rollups!(graph:, lane_id:, turn_ids:)
        turn_ids = Array(turn_ids).map(&:to_s).uniq
        return if turn_ids.empty?

        projector =
          if graph.attachable.is_a?(Conversation)
            Conversation::TurnExecutionProjector.new(graph: graph, lane_id: lane_id)
          end
        now = Time.current

        turn_ids.each do |turn_id|
          attrs = projector ? projector.execution_rollup_for_turn_id(turn_id) : empty_execution_rollup_attributes

          where(graph_id: graph.id, lane_id: lane_id, id: turn_id).update_all(
            attrs.merge(updated_at: now),
          )
        end
      end

      def self.advance_execution_event_cursor!(graph:, lane_id:, turn_id:, event_id:)
        return if turn_id.blank? || event_id.blank?

        where(graph_id: graph.id, lane_id: lane_id, id: turn_id).update_all(
          execution_event_cursor: event_id,
          updated_at: Time.current,
        )
      end

      def self.empty_execution_rollup_attributes
        {
          execution_activity_count: 0,
          execution_status: nil,
          execution_phase: nil,
          execution_diagnostic_level: nil,
          execution_event_cursor: nil,
          execution_summary: {},
          execution_hidden_summary: {},
          execution_preview_activities: [],
          execution_updated_at: nil,
        }
      end

      public_class_method :refresh_execution_rollups!, :advance_execution_event_cursor!, :empty_execution_rollup_attributes

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
