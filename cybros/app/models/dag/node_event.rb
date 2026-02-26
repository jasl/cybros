module DAG
  class NodeEvent < ApplicationRecord
    self.table_name = "dag_node_events"

    OUTPUT_DELTA = "output_delta"
    OUTPUT_COMPACTED = "output_compacted"
    PROGRESS = "progress"
    LOG = "log"

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :node_events
    belongs_to :node, class_name: "DAG::Node", inverse_of: :node_events

    validates :kind, presence: true

    before_validation :normalize_payload
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
  end
end
