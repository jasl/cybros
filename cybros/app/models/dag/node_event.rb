module DAG
  class NodeEvent < ApplicationRecord
    self.table_name = "dag_node_events"

    OUTPUT_DELTA = "output_delta"
    OUTPUT_COMPACTED = "output_compacted"
    PROGRESS = "progress"
    LOG = "log"
    ACTIVITY_PLANNED = "activity_planned"
    ACTIVITY_STARTED = "activity_started"
    ACTIVITY_UPDATED = "activity_updated"
    ACTIVITY_WAITING = "activity_waiting"
    ACTIVITY_FINISHED = "activity_finished"
    ACTIVITY_FAILED = "activity_failed"

    ACTIVITY_EVENT_KINDS = [
      ACTIVITY_PLANNED,
      ACTIVITY_STARTED,
      ACTIVITY_UPDATED,
      ACTIVITY_WAITING,
      ACTIVITY_FINISHED,
      ACTIVITY_FAILED,
    ].freeze

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :node_events
    belongs_to :node, class_name: "DAG::Node", inverse_of: :node_events

    validates :kind, presence: true

    before_validation :normalize_payload
    after_create_commit :refresh_turn_execution_rollup
    after_create_commit :broadcast_to_conversation

    scope :ordered, -> { order(:id) }

    private

      def broadcast_to_conversation
        conversation = graph&.attachable
        return unless conversation.is_a?(::Conversation)

        ::ConversationChannel.broadcast_node_event(conversation, self)
      rescue StandardError => e
        Cybros::RateLimitedLog.warn(
          "dag.node_event.broadcast_to_conversation",
          message: {
            msg: "broadcast_to_conversation_failed",
            graph_id: graph_id&.to_s,
            node_id: node_id&.to_s,
            kind: kind.to_s,
            error_class: e.class.name,
            error: Cybros::RateLimitedLog.sanitize(e.message),
          }.to_json
        )
      end

      def normalize_payload
        if payload.is_a?(Hash)
          self.payload = payload.deep_stringify_keys
        else
          self.payload = {}
        end
      end

      def refresh_turn_execution_rollup
        return if turn_id.blank?
        return unless graph&.attachable.is_a?(::Conversation)
        return unless execution_rollup_relevant_event?

        if activity_rollup_event?
          DAG::Turn.refresh_execution_rollups!(graph: graph, lane_id: node.lane_id, turn_ids: [turn_id])
        elsif assistant_output_replay_event?
          DAG::Turn.advance_execution_event_cursor!(graph: graph, lane_id: node.lane_id, turn_id: turn_id, event_id: id)
        end
      end

      def execution_rollup_relevant_event?
        activity_rollup_event? || assistant_output_replay_event?
      end

      def activity_rollup_event?
        ACTIVITY_EVENT_KINDS.include?(kind.to_s)
      end

      def assistant_output_replay_event?
        return false unless kind.to_s.in?([OUTPUT_DELTA, OUTPUT_COMPACTED])

        node_type = node&.node_type.to_s
        node_type.in?(
          [
            Messages::AgentMessage.node_type_key,
            Messages::CharacterMessage.node_type_key,
          ],
        )
      end
  end
end
