class Event < ApplicationRecord
  belongs_to :conversation
  belongs_to :subject, polymorphic: true

  validates :event_type, presence: true

  after_create_commit :broadcast_node_state_change

  private

    def broadcast_node_state_change
      return unless event_type.to_s == "node_state_changed"
      return unless subject_type.to_s == "DAG::Node"

      node = subject

      ConversationChannel.broadcast_to(
        conversation,
        {
          "type" => "node_state",
          "conversation_id" => conversation_id.to_s,
          "event_id" => id.to_s,
          "turn_id" => node&.turn_id.to_s,
          "node_id" => subject_id.to_s,
          "from" => particulars.is_a?(Hash) ? particulars["from"].to_s : "",
          "to" => particulars.is_a?(Hash) ? particulars["to"].to_s : "",
          "occurred_at" => created_at&.iso8601,
        }
      )

      to = particulars.is_a?(Hash) ? particulars["to"].to_s : ""
      return unless Conversation::TERMINAL_NODE_STATES.include?(to)

      return unless node.node_type.to_s == Messages::AgentMessage.node_type_key
      message = conversation.message_for_node_id(node_id: node.id, mode: :full)

      Turbo::StreamsChannel.broadcast_replace_to(
        [conversation, :messages],
        target: "message_#{node.id}",
        partial: "conversation_messages/message",
        locals: { message: message },
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
