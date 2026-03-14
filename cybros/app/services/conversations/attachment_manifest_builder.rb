module Conversations
  class AttachmentManifestBuilder
    class << self
      def build(conversation:, source_message_node_id:)
        new(
          conversation: conversation,
          source_message_node_id: source_message_node_id,
        ).build
      end
    end

    def initialize(conversation:, source_message_node_id:)
      @conversation = conversation
      @source_message_node_id = source_message_node_id.to_s
    end

    def build
      attachments.map do |attachment|
        {
          "id" => attachment.id,
          "position" => attachment.position,
          "source_message_node_id" => attachment.source_message_node_id.to_s,
          "filename" => attachment.filename,
          "content_type" => attachment.content_type,
          "byte_size" => attachment.byte_size,
          "digest" => attachment.digest,
        }
      end
    end

    private

      attr_reader :conversation, :source_message_node_id

      def attachments
        conversation
          .conversation_attachments
          .where(source_message_node_id: source_message_node_id)
          .includes(file_attachment: :blob)
          .order(:position, :id)
      end
  end
end
