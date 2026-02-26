class Event < ApplicationRecord
  belongs_to :conversation
  belongs_to :subject, polymorphic: true

  validates :event_type, presence: true

  after_create_commit :broadcast_node_state_change

  private

    def broadcast_node_state_change
      return unless event_type.to_s == DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED
      return unless subject_type.to_s == "DAG::Node"

      ConversationChannel.broadcast_to(
        conversation,
        {
          "type" => "node_state",
          "conversation_id" => conversation_id.to_s,
          "node_id" => subject_id.to_s,
          "from" => particulars.is_a?(Hash) ? particulars["from"].to_s : "",
          "to" => particulars.is_a?(Hash) ? particulars["to"].to_s : "",
          "occurred_at" => created_at&.iso8601,
        }
      )
    rescue StandardError => e
      Cybros::RateLimitedLog.warn(
        "event.broadcast_node_state_change",
        message: {
          msg: "broadcast_node_state_change_failed",
          conversation_id: conversation_id&.to_s,
          subject_type: subject_type.to_s,
          subject_id: subject_id&.to_s,
          error_class: e.class.name,
          error: Cybros::RateLimitedLog.sanitize(e.message),
        }.to_json
      )
    end
end
